#include <windows.h>
#include <wrl.h>
#include <WebView2.h>
#include "com_callback.h"
#include <cassert>
#include <memory>
#include <stdexcept>

int main() {
    bool invoked = false;
    auto lifetime = std::make_shared<int>(42);
    std::weak_ptr<int> weak = lifetime;
    auto callback = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [lifetime, &invoked](HRESULT status, ICoreWebView2Environment *environment) {
            invoked = true;
            assert(environment == nullptr);
            return status;
        });
    lifetime.reset();
    assert(!weak.expired());
    assert(callback->Invoke(S_FALSE, nullptr) == S_FALSE && invoked);
    assert(callback->QueryInterface(__uuidof(IUnknown), nullptr) == E_POINTER);
    IUnknown *unknown = nullptr;
    assert(callback->QueryInterface(__uuidof(IUnknown), reinterpret_cast<void **>(&unknown)) == S_OK);
    callback.Reset();
    assert(!weak.expired());
    unknown->Release();
    assert(weak.expired());

    auto throwing = Callback<ICoreWebView2WebMessageReceivedEventHandler>(
        [](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *) -> HRESULT {
            throw std::runtime_error("test");
        });
    assert(throwing->Invoke(nullptr, nullptr) == E_FAIL);
    void *object = reinterpret_cast<void *>(1);
    assert(throwing->QueryInterface(__uuidof(ICoreWebView2Controller2), &object) == E_NOINTERFACE);
    assert(object == nullptr);
    return 0;
}
