set(LUAJIT_SOURCE_DIR "${PROJECT_SOURCE_DIR}/deps/luajit")
set(LUAJIT_BUILD_DIR "${LUAJIT_SOURCE_DIR}/src")

if(MSVC)
  set(LUAJIT_LIBRARY "${LUAJIT_BUILD_DIR}/lua51.lib")
  set(LUAJIT_RUNTIME "${LUAJIT_BUILD_DIR}/lua51.dll")
  add_custom_command(
    OUTPUT "${LUAJIT_LIBRARY}" "${LUAJIT_RUNTIME}"
    COMMAND cmd /c msvcbuild.bat mixed
    WORKING_DIRECTORY "${LUAJIT_BUILD_DIR}"
    COMMENT "Building LuaJITMT (simd)"
    VERBATIM
  )
else()
  find_program(LOVR_MAKE_EXECUTABLE NAMES gmake make)
  if(NOT LOVR_MAKE_EXECUTABLE)
    message(FATAL_ERROR "A Make implementation is required to build LuaJITMT")
  endif()

  if(CMAKE_CROSSCOMPILING)
    find_program(LUAJIT_HOST_CC NAMES cc clang gcc)
  else()
    set(LUAJIT_HOST_CC "${CMAKE_C_COMPILER}")
  endif()
  if(NOT LUAJIT_HOST_CC)
    message(FATAL_ERROR "A host C compiler is required to build LuaJITMT")
  endif()

  set(LUAJIT_LIBRARY "${LUAJIT_BUILD_DIR}/libluajit.so")
  set(LUAJIT_MAKE_ARGS
    "BUILDMODE=dynamic"
    "HOST_CC=${LUAJIT_HOST_CC}"
    "STATIC_CC=${CMAKE_C_COMPILER}"
    "DYNAMIC_CC=${CMAKE_C_COMPILER} -fPIC"
    "TARGET_LD=${CMAKE_C_COMPILER}"
    "TARGET_AR=${CMAKE_AR} rcus"
    "TARGET_STRIP=true"
  )
  if(ANDROID)
    list(APPEND LUAJIT_MAKE_ARGS
      "TARGET_SYS=Linux"
      "TARGET_SHLDFLAGS=-Wl,-z,global"
    )
  elseif(APPLE)
    list(APPEND LUAJIT_MAKE_ARGS
      "TARGET_DYLIBPATH=@rpath/libluajit.so"
    )
  endif()

  add_custom_command(
    OUTPUT "${LUAJIT_LIBRARY}"
    COMMAND
      ${CMAKE_COMMAND} -E env
      "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
      ${LOVR_MAKE_EXECUTABLE} ${LUAJIT_MAKE_ARGS}
    WORKING_DIRECTORY "${LUAJIT_BUILD_DIR}"
    COMMENT "Building LuaJITMT (simd)"
    VERBATIM
  )
endif()

add_custom_target(luajit-build DEPENDS "${LUAJIT_LIBRARY}")
add_library(libluajit SHARED IMPORTED GLOBAL)
add_dependencies(libluajit luajit-build)
set_target_properties(libluajit PROPERTIES
  IMPORTED_LOCATION "${LUAJIT_RUNTIME}"
  IMPORTED_IMPLIB "${LUAJIT_LIBRARY}"
  IMPORTED_SONAME "libluajit.so"
  INTERFACE_INCLUDE_DIRECTORIES "${LUAJIT_BUILD_DIR}"
)

if(NOT MSVC)
  set_target_properties(libluajit PROPERTIES
    IMPORTED_LOCATION "${LUAJIT_LIBRARY}"
    IMPORTED_IMPLIB ""
  )
endif()

set(LOVR_LUA_INCLUDE "${LUAJIT_BUILD_DIR}")
set(LOVR_LUA libluajit)
