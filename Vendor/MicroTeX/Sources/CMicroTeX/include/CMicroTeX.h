// The subset of MicroTeX's C API (lib/wrapper/cwrapper.h) that sangaku calls, declared without the
// library's include paths so Swift can import it.
#ifndef CMICROTEX_H
#define CMICROTEX_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  float width;
  float height;
  float ascent;
} TextLayoutBounds;

typedef struct {
  bool isBold;
  bool isItalic;
  bool isSansSerif;
  bool isMonospace;
  float fontSize;
} FontDesc;

typedef unsigned int (*CBCreateTextLayout)(const char* txt, FontDesc* f);
typedef void (*CBGetTextLayoutBounds)(unsigned int id, TextLayoutBounds* b);
typedef void (*CBReleaseTextLayout)(unsigned int id);
typedef bool (*CBIsPathExists)(int id);

typedef void* FontMetaPtr;
typedef void* RenderPtr;
typedef void* DrawingData;

const char* microtex_version(void);
void microtex_registerCallbacks(CBCreateTextLayout createTextLayout,
                                CBGetTextLayoutBounds getTextLayoutBounds,
                                CBReleaseTextLayout releaseTextLayout,
                                CBIsPathExists isPathExists);
FontMetaPtr microtex_init(unsigned long len, const unsigned char* data);
bool microtex_isInited(void);
const char* microtex_getFontName(FontMetaPtr ptr);
void microtex_releaseFontMeta(FontMetaPtr ptr);
void microtex_setDefaultMathFont(const char* name);
void microtex_setRenderGlyphUsePath(bool use);
RenderPtr microtex_parseRender(const char* tex, int width, float textSize, float lineSpace,
                               unsigned int color, bool fillWidth, bool enableOverrideTeXStyle,
                               unsigned int texStyle);
void microtex_deleteRender(RenderPtr render);
DrawingData microtex_getDrawingData(RenderPtr render, int x, int y);
void microtex_freeDrawingData(DrawingData data);
int microtex_getRenderWidth(RenderPtr render);
int microtex_getRenderHeight(RenderPtr render);
int microtex_getRenderDepth(RenderPtr render);
void microtex_setRenderTextSize(RenderPtr render, float size);

// Shims (safe_parse.cpp): the same calls, but a C++ exception never escapes. Each returns NULL and fills
// `error` on failure. sangaku calls these instead of the throwing originals.
FontMetaPtr microtex_tryInit(unsigned long len, const unsigned char* data, char* error, int errorLength);
/// `display` selects display style, otherwise text style.
RenderPtr microtex_tryParse(const char* tex, float textSize, bool display, char* error, int errorLength);
DrawingData microtex_tryDrawingData(RenderPtr render, int x, int y, char* error, int errorLength);

#ifdef __cplusplus
}
#endif

#endif
