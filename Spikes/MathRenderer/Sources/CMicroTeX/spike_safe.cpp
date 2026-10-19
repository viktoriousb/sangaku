// Spike shim: MicroTeX reports parse errors as C++ exceptions, which must not cross into Swift.
#include <cstring>
#include <exception>
#include "microtex.h"
#include "wrapper/cwrapper.h"

extern "C" RenderPtr microtex_spike_tryParse(
  const char* tex, float textSize, bool display, char* error, int errorLength
) {
  try {
    if (error && errorLength > 0) error[0] = 0;
    return microtex_parseRender(tex, 0, textSize, textSize / 3.f, 0xff000000, false, true, display ? 0u : 2u);
  } catch (const std::exception& e) {
    if (error && errorLength > 0) { std::strncpy(error, e.what(), errorLength - 1); error[errorLength - 1] = 0; }
  } catch (...) {
    if (error && errorLength > 0) { std::strncpy(error, "unknown error", errorLength - 1); error[errorLength - 1] = 0; }
  }
  return nullptr;
}
