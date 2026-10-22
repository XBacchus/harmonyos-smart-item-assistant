#include "napi/native_api.h"
#include "onnxruntime_c_api.h"
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include <dlfcn.h>

namespace {
// API contract is compiled against the pinned OHOS 1.16.3 headers.
const OrtApi* api = nullptr;
const OrtApiBase* base = nullptr;
void loadRuntime() {
    if (api) return;
    void* handle = dlopen("libonnxruntime.so", RTLD_NOW | RTLD_LOCAL);
    if (!handle) throw std::runtime_error(std::string("ORT dlopen: ") + dlerror());
    auto getter = reinterpret_cast<const OrtApiBase* (*)()>(dlsym(handle,"OrtGetApiBase"));
    if (!getter) throw std::runtime_error(std::string("ORT dlsym: ") + dlerror());
    base = getter();
    api = base->GetApi(ORT_API_VERSION);
    if (!api) throw std::runtime_error("ORT API version mismatch");
}
std::mutex sessionMutex;
OrtEnv* environment = nullptr;
OrtSession* activeSession = nullptr;
std::string activePath;
using Clock = std::chrono::steady_clock;
double milliseconds(Clock::time_point start) { return std::chrono::duration<double, std::milli>(Clock::now()-start).count(); }
void check(OrtStatus* status) {
    if (!status) return;
    std::string message = api->GetErrorMessage(status);
    api->ReleaseStatus(status);
    throw std::runtime_error(message);
}
void napiCheck(napi_status status) { if (status != napi_ok) throw std::runtime_error("Invalid native argument or allocation failure"); }
std::string stringArg(napi_env env, napi_value value) {
    size_t size = 0;
    napiCheck(napi_get_value_string_utf8(env, value, nullptr, 0, &size));
    if (size == 0 || size > 4096) throw std::runtime_error("Invalid model path");
    std::vector<char> buffer(size+1);
    napiCheck(napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &size));
    return std::string(buffer.data(), size);
}
void dimensions(OrtSession* session, bool input) {
    OrtTypeInfo* info = nullptr;
    check(input ? api->SessionGetInputTypeInfo(session, 0, &info) : api->SessionGetOutputTypeInfo(session, 0, &info));
    std::unique_ptr<OrtTypeInfo, decltype(api->ReleaseTypeInfo)> guard(info, api->ReleaseTypeInfo);
    const OrtTensorTypeAndShapeInfo* tensor = nullptr;
    check(api->CastTypeInfoToTensorInfo(info, &tensor));
    if (!tensor) throw std::runtime_error("Expected tensor model IO");
    ONNXTensorElementDataType type;
    check(api->GetTensorElementType(tensor, &type));
    size_t count = 0;
    check(api->GetDimensionsCount(tensor, &count));
    std::vector<int64_t> shape(count);
    check(api->GetDimensions(tensor, shape.data(), count));
    const std::vector<int64_t> expected = input ? std::vector<int64_t>{1,3,640,640} : std::vector<int64_t>{1,84,8400};
    if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || shape != expected) throw std::runtime_error("Incompatible YOLOv13 model IO contract");
}
OrtSession* createSession(const std::string& path) {
    loadRuntime();
    if (!environment) check(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "SmartItem", &environment));
    OrtSessionOptions* options = nullptr;
    check(api->CreateSessionOptions(&options));
    std::unique_ptr<OrtSessionOptions, decltype(api->ReleaseSessionOptions)> optionGuard(options, api->ReleaseSessionOptions);
    check(api->SetIntraOpNumThreads(options, 2));
    check(api->SetInterOpNumThreads(options, 1));
    check(api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
    check(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL));
    OrtSession* session = nullptr;
    check(api->CreateSession(environment, path.c_str(), options, &session));
    std::unique_ptr<OrtSession, decltype(api->ReleaseSession)> guard(session, api->ReleaseSession);
    size_t inputs=0, outputs=0;
    check(api->SessionGetInputCount(session, &inputs));
    check(api->SessionGetOutputCount(session, &outputs));
    if (inputs != 1 || outputs != 1) throw std::runtime_error("Expected one model input and one output");
    dimensions(session, true); dimensions(session, false);
    return guard.release();
}
void numberProperty(napi_env env, napi_value obj, const char* key, double value) {
    napi_value out; napiCheck(napi_create_double(env,value,&out)); napiCheck(napi_set_named_property(env,obj,key,out));
}
napi_value infer(napi_env env, napi_callback_info info) {
    try {
        size_t argc=2; napi_value args[2];
        napiCheck(napi_get_cb_info(env,info,&argc,args,nullptr,nullptr));
        if (argc!=2) throw std::runtime_error("infer requires a path and NCHW float32 ArrayBuffer");
        auto path=stringArg(env,args[0]);
        void* input=nullptr; size_t inputSize=0;
        napiCheck(napi_get_arraybuffer_info(env,args[1],&input,&inputSize));
        if (inputSize!=1*3*640*640*sizeof(float)) throw std::runtime_error("Unexpected input tensor length");
        std::lock_guard<std::mutex> lock(sessionMutex);
        double loadMs=0;
        if (!activeSession || activePath!=path) {
            auto start=Clock::now();
            OrtSession* replacement=createSession(path);
            if(activeSession) api->ReleaseSession(activeSession);
            activeSession=replacement; activePath=path; loadMs=milliseconds(start);
        }
        OrtMemoryInfo* memory=nullptr;
        check(api->CreateCpuMemoryInfo(OrtArenaAllocator,OrtMemTypeDefault,&memory));
        std::unique_ptr<OrtMemoryInfo,decltype(api->ReleaseMemoryInfo)> memoryGuard(memory,api->ReleaseMemoryInfo);
        const int64_t shape[]={1,3,640,640}; OrtValue* inputTensor=nullptr;
        check(api->CreateTensorWithDataAsOrtValue(memory,input,inputSize,shape,4,ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,&inputTensor));
        std::unique_ptr<OrtValue,decltype(api->ReleaseValue)> inputGuard(inputTensor,api->ReleaseValue);
        OrtAllocator* allocator=nullptr; check(api->GetAllocatorWithDefaultOptions(&allocator));
        char* inputName=nullptr; char* outputName=nullptr;
        check(api->SessionGetInputName(activeSession,0,allocator,&inputName));
        std::unique_ptr<char,void(*)(char*)> inputNameGuard(inputName,[](char* p){OrtAllocator* a=nullptr; if(!api->GetAllocatorWithDefaultOptions(&a))a->Free(a,p);});
        check(api->SessionGetOutputName(activeSession,0,allocator,&outputName));
        std::unique_ptr<char,void(*)(char*)> outputNameGuard(outputName,[](char* p){OrtAllocator* a=nullptr; if(!api->GetAllocatorWithDefaultOptions(&a))a->Free(a,p);});
        const char* inputNames[]={inputName}; const char* outputNames[]={outputName};
        const OrtValue* inputs[]={inputTensor}; OrtValue* output=nullptr;
        auto start=Clock::now();
        check(api->Run(activeSession,nullptr,inputNames,inputs,1,outputNames,1,&output));
        double inferenceMs=milliseconds(start);
        std::unique_ptr<OrtValue,decltype(api->ReleaseValue)> outputGuard(output,api->ReleaseValue);
        OrtTensorTypeAndShapeInfo* outputInfo=nullptr; check(api->GetTensorTypeAndShape(output,&outputInfo));
        std::unique_ptr<OrtTensorTypeAndShapeInfo,decltype(api->ReleaseTensorTypeAndShapeInfo)> outputInfoGuard(outputInfo,api->ReleaseTensorTypeAndShapeInfo);
        size_t elements=0; check(api->GetTensorShapeElementCount(outputInfo,&elements));
        if(elements!=84*8400)throw std::runtime_error("Unexpected model output length");
        void* data=nullptr; check(api->GetTensorMutableData(output,&data));
        void* copy=nullptr; napi_value buffer,result,version;
        napiCheck(napi_create_arraybuffer(env,elements*sizeof(float),&copy,&buffer));
        std::memcpy(copy,data,elements*sizeof(float));
        napiCheck(napi_create_object(env,&result));
        napiCheck(napi_set_named_property(env,result,"output",buffer));
        numberProperty(env,result,"inferenceMs",inferenceMs); numberProperty(env,result,"loadMs",loadMs);
        napiCheck(napi_create_string_utf8(env,base->GetVersionString(),NAPI_AUTO_LENGTH,&version));
        napiCheck(napi_set_named_property(env,result,"runtime",version));
        return result;
    } catch(const std::exception& e) { napi_throw_error(env,"INFERENCE_ERROR",e.what()); return nullptr; }
}
napi_value validate(napi_env env,napi_callback_info info) {
    try {
        size_t argc=1; napi_value arg; napiCheck(napi_get_cb_info(env,info,&argc,&arg,nullptr,nullptr));
        if(argc!=1)throw std::runtime_error("Model path required");
        auto path=stringArg(env,arg); std::lock_guard<std::mutex> lock(sessionMutex);
        auto* session=createSession(path); api->ReleaseSession(session);
        napi_value result; napiCheck(napi_create_string_utf8(env,base->GetVersionString(),NAPI_AUTO_LENGTH,&result)); return result;
    }catch(const std::exception& e){napi_throw_error(env,"MODEL_ERROR",e.what());return nullptr;}
}
napi_value init(napi_env env,napi_value exports) {
    napi_property_descriptor properties[]={
        {"infer",nullptr,infer,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"validate",nullptr,validate,nullptr,nullptr,nullptr,napi_default,nullptr}
    };
    napi_define_properties(env,exports,2,properties); return exports;
}
}
static napi_module module={1,0,nullptr,init,"detector",nullptr,{0}};
extern "C" __attribute__((constructor)) void registerDetector(){napi_module_register(&module);}
