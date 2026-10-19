// MicroTeX reports errors as C++ exceptions, which must not cross into Swift. Every entry point sangaku calls
// that can throw goes through one of these wrappers, which return NULL and fill `error` instead.
#include <cstring>
#include <exception>
#include "microtex.h"
#include "wrapper/cwrapper.h"

static void clearError(char* error, int errorLength) {
  if (error && errorLength > 0) error[0] = 0;
}

static void setError(char* error, int errorLength, const char* message) {
  if (error && errorLength > 0) {
    std::strncpy(error, message, errorLength - 1);
    error[errorLength - 1] = 0;
  }
}

extern "C" FontMetaPtr microtex_tryInit(unsigned long len, const unsigned char* data, char* error, int errorLength) {
  clearError(error, errorLength);
  try {
    return microtex_init(len, data);
  } catch (const std::exception& e) {
    setError(error, errorLength, e.what());
  } catch (...) {
    setError(error, errorLength, "unknown error");
  }
  return nullptr;
}

extern "C" RenderPtr microtex_tryParse(
  const char* tex, float textSize, bool display, char* error, int errorLength
) {
  clearError(error, errorLength);
  try {
    return microtex_parseRender(tex, 0, textSize, textSize / 3.f, 0xff000000, false, true, display ? 0u : 2u);
  } catch (const std::exception& e) {
    setError(error, errorLength, e.what());
  } catch (...) {
    setError(error, errorLength, "unknown error");
  }
  return nullptr;
}

extern "C" DrawingData microtex_tryDrawingData(RenderPtr render, int x, int y, char* error, int errorLength) {
  clearError(error, errorLength);
  try {
    return microtex_getDrawingData(render, x, y);
  } catch (const std::exception& e) {
    setError(error, errorLength, e.what());
  } catch (...) {
    setError(error, errorLength, "unknown error");
  }
  return nullptr;
}
