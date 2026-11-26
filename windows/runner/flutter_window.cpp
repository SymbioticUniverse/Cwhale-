#include "flutter_window.h"

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <filesystem>
#include <optional>
#include <string>
#include <unordered_set>
#include <variant>

#include <shellapi.h>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty() || value.find('\0') != std::string::npos) {
    return {};
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return {};
  }
  std::wstring result(length, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) != length) {
    return {};
  }
  return result;
}

const std::string* StringArgument(const flutter::EncodableMap* arguments,
                                  const char* key) {
  if (arguments == nullptr) {
    return nullptr;
  }
  const auto found =
      arguments->find(flutter::EncodableValue(std::string(key)));
  if (found == arguments->end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&found->second);
}

bool IsHttpUrl(const std::string& value) {
  std::string scheme = value.substr(0, std::min<size_t>(value.size(), 8));
  std::transform(scheme.begin(), scheme.end(), scheme.begin(),
                 [](unsigned char character) {
                   return static_cast<char>(std::tolower(character));
                 });
  return scheme.rfind("https://", 0) == 0 ||
         scheme.rfind("http://", 0) == 0;
}

bool IsSupportedDocument(const std::filesystem::path& path) {
  std::wstring extension = path.extension().wstring();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  static const std::unordered_set<std::wstring> allowed_extensions = {
      L".docx", L".pptx", L".xlsx", L".csv", L".txt", L".md",
      L".pdf",  L".png",  L".jpg",  L".jpeg", L".webp", L".gif"};
  return allowed_extensions.find(extension) != allowed_extensions.end();
}

void OpenTarget(
    const std::wstring& target,
    const std::string& error_code,
    const std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>&
        result) {
  const auto shell_result = reinterpret_cast<INT_PTR>(
      ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr,
                    SW_SHOWNORMAL));
  if (shell_result <= 32) {
    result->Error(error_code, "Windows could not open the requested item.");
    return;
  }
  result->Success();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  local_files_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.cwhale/local_files",
      &flutter::StandardMethodCodec::GetInstance());
  local_files_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "openUrl") {
          const auto* url = StringArgument(arguments, "url");
          if (url == nullptr || !IsHttpUrl(*url)) {
            result->Error("invalid_url",
                          "Only HTTP and HTTPS links are allowed.");
            return;
          }
          const auto wide_url = WideFromUtf8(*url);
          if (wide_url.empty()) {
            result->Error("invalid_url", "The URL is invalid.");
            return;
          }
          OpenTarget(wide_url, "open_url_failed", result);
          return;
        }

        if (call.method_name() == "openWith") {
          const auto* path_value = StringArgument(arguments, "path");
          if (path_value == nullptr) {
            result->Error("invalid_path", "The file path is invalid.");
            return;
          }
          const auto wide_path = WideFromUtf8(*path_value);
          if (wide_path.empty()) {
            result->Error("invalid_path", "The file path is malformed.");
            return;
          }
          const std::filesystem::path path(wide_path);
          std::error_code filesystem_error;
          if (!path.is_absolute() ||
              !std::filesystem::is_regular_file(path, filesystem_error) ||
              filesystem_error || !IsSupportedDocument(path)) {
            result->Error("unsupported_file",
                          "The file is missing or its type is unsupported.");
            return;
          }
          OpenTarget(wide_path, "open_file_failed", result);
          return;
        }

        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  local_files_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_GETMINMAXINFO: {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      if (limits != nullptr) {
        // Keep a usable chat and composer area while allowing compact laptop
        // displays to shrink below the wide-layout breakpoint.
        limits->ptMinTrackSize.x = 900;
        limits->ptMinTrackSize.y = 600;
      }
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
