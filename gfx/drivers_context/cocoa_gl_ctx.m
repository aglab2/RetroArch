/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2013-2014 - Jason Fetters
 *  Copyright (C) 2011-2017 - Daniel De Matteis
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#ifdef HAVE_CONFIG_H
#include "../../config.h"
#endif

#if TARGET_OS_IPHONE
#include <CoreGraphics/CoreGraphics.h>
#else
#include <ApplicationServices/ApplicationServices.h>
#endif
#ifdef OSX
#include "MGLKit.h"
#elif defined(HAVE_COCOATOUCH)
#include <GLKit/GLKit.h>
#endif

#include <retro_assert.h>
#include <retro_timers.h>
#include <compat/apple_compat.h>
#include <string/stdstring.h>

#include "../../ui/drivers/ui_cocoa.h"
#include "../../ui/drivers/cocoa/cocoa_common.h"
#include "../../ui/drivers/cocoa/apple_platform.h"
#include "../../configuration.h"
#include "../../retroarch.h"
#include "../../verbosity.h"
#ifdef HAVE_METAL
#include "../common/metal_common.h"
#endif

#if defined(HAVE_COCOATOUCH)
#define GLContextClass  EAGLContext
#define GLFrameworkID   CFSTR("com.apple.opengles")
#else
#define GLContextClass  MGLContext
#define GLFrameworkID   CFSTR("com.google.OpenGLES")
#endif

typedef struct cocoa_ctx_data
{
   int fast_forward_skips;
   unsigned width;
   unsigned height;
   bool is_syncing;
   bool core_hw_context_enable;
   bool use_hw_ctx;
} cocoa_ctx_data_t;

/* TODO/FIXME - static globals */
static enum gfx_ctx_api cocoagl_api = GFX_CTX_NONE;
static GLContextClass* g_hw_ctx     = NULL;
static GLContextClass* g_ctx        = NULL;
static unsigned g_gl_minor          = 0;
static unsigned g_gl_major          = 0;
static MGLKView *glk_view            = NULL;

/* Forward declaration */
CocoaView *cocoaview_get(void);

static uint32_t cocoa_gl_gfx_ctx_get_flags(void *data)
{
   uint32_t flags                 = 0;
   cocoa_ctx_data_t    *cocoa_ctx = (cocoa_ctx_data_t*)data;

   if (cocoa_ctx->core_hw_context_enable)
      BIT32_SET(flags, GFX_CTX_FLAGS_GL_CORE_CONTEXT);

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_ES_API:
#ifdef HAVE_GLSL
         BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_GLSL);
#endif
         break;
      case GFX_CTX_OPENGL_API:
         if (string_is_equal(video_driver_get_ident(), "gl1")) { }
         else if (string_is_equal(video_driver_get_ident(), "glcore"))
         {
#if defined(HAVE_SLANG) && defined(HAVE_SPIRV_CROSS)
            BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_SLANG);
#endif
         }
         else
         {
#ifdef HAVE_GLSL
            BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_GLSL);
#endif
         }
         break;
      default:
         break;
   }

   return flags;
}

static void cocoa_gl_gfx_ctx_set_flags(void *data, uint32_t flags)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   if (BIT32_GET(flags, GFX_CTX_FLAGS_GL_CORE_CONTEXT))
      cocoa_ctx->core_hw_context_enable = true;
}

void *glkitview_init(void)
{
   glk_view                      = [MGLKView new];
#if TARGET_OS_IOS
   glk_view.multipleTouchEnabled = YES;
   glk_view.enableSetNeedsDisplay = NO;
#endif

   return (BRIDGE void *)((MGLKView*)glk_view);
}

void glkitview_bind_fbo(void)
{
   if (glk_view)
      [glk_view bindDrawable];
}

static void cocoa_gl_gfx_ctx_destroy(void *data)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   if (!cocoa_ctx)
      return;
#ifdef OSX
   [MGLContext setCurrentContext:nil];
#else
   [EAGLContext setCurrentContext:nil];
#endif
   g_ctx = nil;

   free(cocoa_ctx);
}

static enum gfx_ctx_api cocoa_gl_gfx_ctx_get_api(void *data) { return cocoagl_api; }

static bool cocoa_gl_gfx_ctx_suppress_screensaver(void *data, bool enable) { return false; }

static void cocoa_gl_gfx_ctx_input_driver(void *data,
      const char *name,
      input_driver_t **input, void **input_data)
{
   *input      = NULL;
   *input_data = NULL;
}

#if MAC_OS_X_VERSION_10_7 && defined(OSX)
/* NOTE: convertRectToBacking only available on MacOS X 10.7 and up.
 * Therefore, make specialized version of this function instead of
 * going through a selector for every call. */
static void cocoa_gl_gfx_ctx_get_video_size_osx10_7_and_up(void *data,
      unsigned* width, unsigned* height)
{
   CocoaView *g_view               = cocoaview_get();
   CGRect _cgrect                  = NSRectToCGRect(g_view.frame);
   CGRect bounds                   = CGRectMake(0, 0, CGRectGetWidth(_cgrect), CGRectGetHeight(_cgrect));
   CGRect cgrect                   = NSRectToCGRect([g_view convertRectToBacking:bounds]);
   GLsizei backingPixelWidth       = CGRectGetWidth(cgrect);
   GLsizei backingPixelHeight      = CGRectGetHeight(cgrect);
   CGRect size                     = CGRectMake(0, 0, backingPixelWidth, backingPixelHeight);
   *width                          = CGRectGetWidth(size);
   *height                         = CGRectGetHeight(size);
}
#elif defined(OSX)
static void cocoa_gl_gfx_ctx_get_video_size(void *data,
      unsigned* width, unsigned* height)
{
   CocoaView *g_view               = cocoaview_get();
   CGRect cgrect                   = NSRectToCGRect([g_view frame]);
   GLsizei backingPixelWidth       = CGRectGetWidth(cgrect);
   GLsizei backingPixelHeight      = CGRectGetHeight(cgrect);
   CGRect size                     = CGRectMake(0, 0, backingPixelWidth, backingPixelHeight);
   *width                          = CGRectGetWidth(size);
   *height                         = CGRectGetHeight(size);
}
#else
/* iOS */
static void cocoa_gl_gfx_ctx_get_video_size(void *data,
      unsigned* width, unsigned* height)
{
   float screenscale               = cocoa_screen_get_native_scale();
   CGRect size                     = glk_view.bounds;
   *width                          = CGRectGetWidth(size)  * screenscale;
   *height                         = CGRectGetHeight(size) * screenscale;
}
#endif

static gfx_ctx_proc_t cocoa_gl_gfx_ctx_get_proc_address(const char *symbol_name)
{
   return (gfx_ctx_proc_t)CFBundleGetFunctionPointerForName(
         CFBundleGetBundleWithIdentifier(GLFrameworkID),
         (BRIDGE CFStringRef)BOXSTRING(symbol_name)
         );
}

static void cocoa_gl_gfx_ctx_bind_hw_render(void *data, bool enable)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   cocoa_ctx->use_hw_ctx = enable;

#ifdef OSX
   if (enable)
   {
      [MGLContext setCurrentContext:g_hw_ctx];
   }
   else
   {
      [MGLContext setCurrentContext:g_ctx];
   }
#else
   if (enable)
   {
      [EAGLContext setCurrentContext:g_hw_ctx];
   }
   else
   {
      [EAGLContext setCurrentContext:g_ctx];
   }
#endif

}

static void cocoa_gl_gfx_ctx_check_window(void *data, bool *quit,
      bool *resize, unsigned *width, unsigned *height)
{
   unsigned new_width, new_height;

   *quit                       = false;

#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_gl_gfx_ctx_get_video_size_osx10_7_and_up(data, &new_width, &new_height);
#else
   cocoa_gl_gfx_ctx_get_video_size(data, &new_width, &new_height);
#endif

   if (new_width != *width || new_height != *height)
   {
      *width  = new_width;
      *height = new_height;
      *resize = true;
   }
}

static void cocoa_gl_gfx_ctx_swap_interval(void *data, int i)
{
   unsigned interval             = (unsigned)i;
#ifdef OSX
   cocoa_ctx_data_t *cocoa_ctx   = (cocoa_ctx_data_t*)data;
   /* < No way to disable Vsync on iOS? */
   /*   Just skip presents so fast forward still works. */
   cocoa_ctx->is_syncing         = interval ? true : false;
   cocoa_ctx->fast_forward_skips = interval ? 0 : 3;
#else
   cocoa_ctx_data_t *cocoa_ctx   = (cocoa_ctx_data_t*)data;
   /* < No way to disable Vsync on iOS? */
   /*   Just skip presents so fast forward still works. */
   cocoa_ctx->is_syncing         = interval ? true : false;
   cocoa_ctx->fast_forward_skips = interval ? 0 : 3;
#endif
}

static void cocoa_gl_gfx_ctx_swap_buffers(void *data)
{
#ifdef OSX
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;
   if (!(--cocoa_ctx->fast_forward_skips < 0))
      return;
   if (glk_view)
      [glk_view display];
   cocoa_ctx->fast_forward_skips = cocoa_ctx->is_syncing ? 0 : 3;
#else
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;
   if (!(--cocoa_ctx->fast_forward_skips < 0))
      return;
   if (glk_view)
      [glk_view display];
   cocoa_ctx->fast_forward_skips = cocoa_ctx->is_syncing ? 0 : 3;
#endif
}

static bool cocoa_gl_gfx_ctx_bind_api(void *data, enum gfx_ctx_api api,
      unsigned major, unsigned minor)
{
   cocoagl_api = api;
   g_gl_minor  = minor;
   g_gl_major  = major;

   return true;
}

#ifdef OSX
static bool cocoa_gl_gfx_ctx_set_video_mode(void *data,
      unsigned width, unsigned height, bool fullscreen)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;
   static bool
      has_went_fullscreen      = false;
   
   if (cocoa_ctx->use_hw_ctx)
      g_hw_ctx      = [[MGLContext alloc] initWithAPI:kMGLRenderingAPIOpenGLES3];
   g_ctx            = [[MGLContext alloc] initWithAPI:kMGLRenderingAPIOpenGLES3];
   glk_view.context = g_ctx;

#ifdef OSX
   [MGLContext setCurrentContext:g_ctx];
#else
   [EAGLContext setCurrentContext:g_ctx];
#endif

   /* TODO/FIXME: Screen mode support. */
   if (fullscreen)
   {
      if (!has_went_fullscreen)
      {
         [glk_view enterFullScreenMode:(BRIDGE NSScreen *)cocoa_screen_get_chosen() withOptions:nil];
         cocoa_show_mouse(data, false);
      }
   }
   else
   {
      if (has_went_fullscreen)
      {
         [glk_view exitFullScreenModeWithOptions:nil];
         [[glk_view window] makeFirstResponder:glk_view];
         cocoa_show_mouse(data, true);
      }

      [[glk_view window] setContentSize:NSMakeSize(width, height)];
   }

   has_went_fullscreen = fullscreen;

   return true;
}

static void *cocoa_gl_gfx_ctx_init(void *video_driver)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)
      calloc(1, sizeof(cocoa_ctx_data_t));

   if (!cocoa_ctx)
      return NULL;

   cocoa_ctx->is_syncing       = true;

#if defined(HAVE_COCOA_METAL)
   [apple_platform setViewType:APPLE_VIEW_TYPE_OPENGL];
#endif

   return cocoa_ctx;
}
#else
static bool cocoa_gl_gfx_ctx_set_video_mode(void *data,
      unsigned width, unsigned height, bool fullscreen)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   if (cocoa_ctx->use_hw_ctx)
      g_hw_ctx      = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
   g_ctx            = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
   glk_view.context = g_ctx;

#ifdef OSX
   [MGLContext setCurrentContext:g_ctx];
#else
   [EAGLContext setCurrentContext:g_ctx];
#endif

   /* TODO: Maybe iOS users should be able to 
    * show/hide the status bar here? */
   return true;
}

static void *cocoa_gl_gfx_ctx_init(void *video_driver)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)
   calloc(1, sizeof(cocoa_ctx_data_t));

   if (!cocoa_ctx)
      return NULL;

   cocoa_ctx->is_syncing       = true;
    
   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_ES_API:
#if defined(HAVE_COCOA_METAL)
         /* The Metal build supports both the OpenGL 
          * and Metal video drivers */
         [apple_platform setViewType:APPLE_VIEW_TYPE_OPENGL_ES];
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }
    
   return cocoa_ctx;
}
#endif

#ifdef HAVE_COCOA_METAL
static bool cocoa_gl_gfx_ctx_set_resize(void *data, unsigned width, unsigned height)
{
   return true;
}
#endif

const gfx_ctx_driver_t gfx_ctx_cocoagl = {
   cocoa_gl_gfx_ctx_init,
   cocoa_gl_gfx_ctx_destroy,
   cocoa_gl_gfx_ctx_get_api,
   cocoa_gl_gfx_ctx_bind_api,
   cocoa_gl_gfx_ctx_swap_interval,
   cocoa_gl_gfx_ctx_set_video_mode,
#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_gl_gfx_ctx_get_video_size_osx10_7_and_up,
#else
   cocoa_gl_gfx_ctx_get_video_size,
#endif
   NULL, /* get_refresh_rate */
   NULL, /* get_video_output_size */
   NULL, /* get_video_output_prev */
   NULL, /* get_video_output_next */
   cocoa_get_metrics,
   NULL, /* translate_aspect */
#ifdef OSX
   cocoa_update_title,
#else
   NULL, /* update_title */
#endif
   cocoa_gl_gfx_ctx_check_window,
#if defined(HAVE_COCOA_METAL)
   cocoa_gl_gfx_ctx_set_resize,
#else
   NULL, /* set_resize */
#endif
   cocoa_has_focus,
   cocoa_gl_gfx_ctx_suppress_screensaver,
#if defined(HAVE_COCOATOUCH)
   false,
#else
   true,
#endif
   cocoa_gl_gfx_ctx_swap_buffers,
   cocoa_gl_gfx_ctx_input_driver,
   cocoa_gl_gfx_ctx_get_proc_address,
   NULL, /* image_buffer_init */
   NULL, /* image_buffer_write */
   NULL, /* show_mouse */
   "cocoagl",
   cocoa_gl_gfx_ctx_get_flags,
   cocoa_gl_gfx_ctx_set_flags,
   cocoa_gl_gfx_ctx_bind_hw_render,
   NULL, /* get_context_data */
   NULL  /* make_current */
};
