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
#include <AppKit/NSScreen.h>
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

#ifdef HAVE_EGL
#include "../common/egl_common.h"
#endif

#ifdef HAVE_ANGLE
#include "../common/angle_common.h"
#endif

#ifdef HAVE_METAL
#include "../common/metal_common.h"
#endif

typedef struct cocoa_egl_ctx_data
{
   int swap_interval;
   unsigned width;
   unsigned height;
} cocoa_egl_ctx_data_t;

static egl_ctx_data_t cocoa_egl;
#ifdef HAVE_DYLIB
static dylib_t  gles_dll_handle = NULL;
static dylib_t  egl_dll_handle = NULL;
#endif

/* Forward declaration */
CocoaView *cocoaview_get(void);

static bool create_gles_context(void* corewindow)
{
   EGLint n, major, minor;
   EGLint format;
   EGLint attribs[] = {
   EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
   EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
   EGL_BLUE_SIZE, 8,
   EGL_GREEN_SIZE, 8,
   EGL_RED_SIZE, 8,
   EGL_ALPHA_SIZE, 8,
   EGL_DEPTH_SIZE, 16,
   EGL_NONE
   };

   EGLint context_attributes[] = {
      EGL_CONTEXT_CLIENT_VERSION, 2,
      EGL_NONE
   };

#ifdef HAVE_ANGLE
   if (!angle_init_context(&cocoa_egl, EGL_DEFAULT_DISPLAY,
      &major, &minor, &n, attribs, NULL))
#else
   if (!egl_init_context(&cocoa_egl, EGL_NONE, EGL_DEFAULT_DISPLAY,
      &major, &minor, &n, attribs, NULL))
#endif
   {
      egl_report_error();
      goto error;
   }

   if (!egl_get_native_visual_id(&cocoa_egl, &format))
      goto error;

   if (!egl_create_context(&cocoa_egl, context_attributes))
   {
      egl_report_error();
      goto error;
   }

   if (!egl_create_surface(&cocoa_egl, corewindow))
   {
      egl_report_error();
      goto error;
   }

   return true;

error:
   return false;
}

static uint32_t cocoa_egl_gfx_ctx_get_flags(void *data)
{
   uint32_t flags                 = 0;

#if defined(HAVE_SLANG) && defined(HAVE_SPIRV_CROSS)
   BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_SLANG);
#endif
#ifdef HAVE_GLSL
   BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_GLSL);
#endif

   return flags;
}

static void cocoa_egl_gfx_ctx_set_flags(void *data, uint32_t flags) { }

static void cocoa_egl_gfx_ctx_destroy(void *data)
{
   cocoa_egl_ctx_data_t *cocoa_ctx = (cocoa_egl_ctx_data_t*)data;

   if (!cocoa_ctx)
      return;

   egl_destroy(&cocoa_egl);

#ifdef HAVE_DYLIB
   dylib_close(egl_dll_handle);
   dylib_close(gles_dll_handle);
#endif

   free(cocoa_ctx);
}

static enum gfx_ctx_api cocoa_egl_gfx_ctx_get_api(void *data) { return GFX_CTX_OPENGL_ES_API; }

static bool cocoa_egl_gfx_ctx_suppress_screensaver(void *data, bool enable) { return false; }

static void cocoa_egl_gfx_ctx_input_driver(void *data,
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
static void cocoa_egl_gfx_ctx_get_video_size_osx10_7_and_up(void *data,
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
static void cocoa_egl_gfx_ctx_get_video_size(void *data,
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
#endif

static gfx_ctx_proc_t cocoa_egl_gfx_ctx_get_proc_address(const char *symbol_name)
{
#ifdef HAVE_DYLIB
   bool is_egl_symbol = 'e' == *symbol_name;
   dylib_t dll_handle = is_egl_symbol ? egl_dll_handle : gles_dll_handle;
   return (gfx_ctx_proc_t) dylib_proc(dll_handle, symbol_name);
#else
   return NULL;
#endif
}

static void cocoa_egl_gfx_ctx_bind_hw_render(void *data, bool enable)
{
   egl_bind_hw_render(&cocoa_egl, enable);
}

static void cocoa_egl_gfx_ctx_check_window(void *data, bool *quit,
      bool *resize, unsigned *width, unsigned *height)
{
   unsigned new_width, new_height;

   *quit                       = false;

#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_egl_gfx_ctx_get_video_size_osx10_7_and_up(data, &new_width, &new_height);
#else
   cocoa_egl_gfx_ctx_get_video_size(data, &new_width, &new_height);
#endif

   if (new_width != *width || new_height != *height)
   {
      *width  = new_width;
      *height = new_height;
      *resize = true;
   }
}

static void cocoa_egl_gfx_ctx_swap_interval(void *data, int i)
{
   unsigned interval           = (unsigned)i;
   cocoa_egl_ctx_data_t *cocoa_ctx = (cocoa_egl_ctx_data_t*)data;

   if (cocoa_ctx->swap_interval != interval)
   {
      cocoa_ctx->swap_interval = interval;
      egl_set_swap_interval(&cocoa_egl, cocoa_ctx->swap_interval);
   }
}

static void cocoa_egl_gfx_ctx_swap_buffers(void *data)
{
   egl_swap_buffers(&cocoa_egl);
}

static bool cocoa_egl_gfx_ctx_bind_api(void *data, enum gfx_ctx_api api,
      unsigned major, unsigned minor)
{
   if (api == GFX_CTX_OPENGL_ES_API)
      return true;

   return false;
}

static void* cocoa_get_corewindow()
{
   MetalView *view = (MetalView *)apple_platform.renderView;
   CALayer *layer = view.layer;
   return (BRIDGE void *)layer;
}

static bool cocoa_egl_gfx_ctx_set_video_mode(void *data,
      unsigned width, unsigned height, bool fullscreen)
{
   NSView *g_view              = apple_platform.renderView;
   cocoa_egl_ctx_data_t *cocoa_ctx = (cocoa_egl_ctx_data_t*)data;
   static bool 
      has_went_fullscreen      = false;
   cocoa_ctx->width            = width;
   cocoa_ctx->height           = height;

   RARCH_LOG("[macOS]: Native window size: %u x %u.\n",
         cocoa_ctx->width, cocoa_ctx->height);

   /* TODO: Screen mode support. */
   if (fullscreen)
   {
      if (!has_went_fullscreen)
      {
         [g_view enterFullScreenMode:(BRIDGE NSScreen *)cocoa_screen_get_chosen() withOptions:nil];
         cocoa_show_mouse(data, false);
      }
   }
   else
   {
      if (has_went_fullscreen)
      {
         [g_view exitFullScreenModeWithOptions:nil];
         [[g_view window] makeFirstResponder:g_view];
         cocoa_show_mouse(data, true);
      }

      [[g_view window] setContentSize:NSMakeSize(width, height)];
   }

   has_went_fullscreen = fullscreen;

   if (!create_gles_context(cocoa_get_corewindow()))
   {
      RARCH_ERR("[COCOA EGL]: create_gles_context failed.\n");
      goto error;
   }

   cocoa_egl_gfx_ctx_swap_interval(data, cocoa_ctx->swap_interval);
   return true;

error:
   cocoa_egl_gfx_ctx_destroy(data);
   return false;
}

static void *cocoa_egl_gfx_ctx_init(void *video_driver)
{
   cocoa_egl_ctx_data_t *cocoa_ctx = (cocoa_egl_ctx_data_t*)
   calloc(1, sizeof(cocoa_egl_ctx_data_t));

   if (!cocoa_ctx)
      return NULL;

   // We just need not OpenGL here really
   [apple_platform setViewType:APPLE_VIEW_TYPE_METAL];

#ifdef HAVE_DYLIB
   gles_dll_handle = dylib_load("@executable_path/../Frameworks/libGLESv2.dylib");
   egl_dll_handle = dylib_load("@executable_path/../Frameworks/libEGL.dylib");
#endif

   return cocoa_ctx;
}

static bool cocoa_egl_gfx_ctx_set_resize(void *data, unsigned width, unsigned height)
{
   return true;
}

const gfx_ctx_driver_t gfx_ctx_cocoaegl = {
   cocoa_egl_gfx_ctx_init,
   cocoa_egl_gfx_ctx_destroy,
   cocoa_egl_gfx_ctx_get_api,
   cocoa_egl_gfx_ctx_bind_api,
   cocoa_egl_gfx_ctx_swap_interval,
   cocoa_egl_gfx_ctx_set_video_mode,
#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_egl_gfx_ctx_get_video_size_osx10_7_and_up,
#else
   cocoa_egl_gfx_ctx_get_video_size,
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
   cocoa_egl_gfx_ctx_check_window,
   cocoa_egl_gfx_ctx_set_resize,
   cocoa_has_focus,
   cocoa_egl_gfx_ctx_suppress_screensaver,
#if defined(HAVE_COCOATOUCH)
   false,
#else
   true,
#endif
   cocoa_egl_gfx_ctx_swap_buffers,
   cocoa_egl_gfx_ctx_input_driver,
   cocoa_egl_gfx_ctx_get_proc_address,
   NULL, /* image_buffer_init */
   NULL, /* image_buffer_write */
   NULL, /* show_mouse */
   "cocoaegl",
   cocoa_egl_gfx_ctx_get_flags,
   cocoa_egl_gfx_ctx_set_flags,
   cocoa_egl_gfx_ctx_bind_hw_render,
   NULL /* get_context_data */,
   NULL  /* make_current */
};
