#!/usr/bin/env bash

# Environment variables:
# BUILDER_ARCH: the target architecture (required)
# BUILDER_CROSS_COMPILE: 'true' indicates if we're cross-compiling
# BUILDER_EXTRA_CMAKE_FLAGS: extra flags appended to CMake
# BUILDER_OS: the target operating system (required)
# BUILDER_OS_VERSION: the version of the target operating system
# BUILDER_TARGET_TRIPLE: the triple of the target (required if cross-compiling)
# GITHUB_WORKSPACE: the path to the Git repository checkout in GitHub actions (required)

set -ueo pipefail

version="$1"
llvm_dir="$GITHUB_WORKSPACE/llvm/llvm"
clang_dir="$GITHUB_WORKSPACE/llvm/clang"
native_build_dir="$GITHUB_WORKSPACE/build_native"
install_name="llvm-$version"
build_dir="$GITHUB_WORKSPACE/$install_name"
base_cmake_flags=$(cat << EOF
-D CMAKE_BUILD_TYPE=Release
-D COMPILER_RT_INCLUDE_TESTS=Off
-D COMPILER_RT_USE_LIBCXX=Off
-D LLVM_ENABLE_PROJECTS=clang
-D LLVM_ENABLE_TERMINFO=Off
-D LLVM_ENABLE_ZLIB=Off
-D LLVM_INCLUDE_BENCHMARKS=Off
-D LLVM_INCLUDE_EXAMPLES=Off
-D LLVM_INCLUDE_TESTS=Off
EOF
)

if [ "$BUILDER_CROSS_COMPILE" = true ]; then
  export MACOSX_DEPLOYMENT_TARGET=11
extra_cmake_flags=$(cat << EOF
-D CLANG_TABLEGEN=$native_build_dir/bin/clang-tblgen
-D LLVM_CONFIG_PATH=$native_build_dir/bin/llvm-config
-D LLVM_DEFAULT_TARGET_TRIPLE=$BUILDER_TARGET_TRIPLE
-D LLVM_TABLEGEN=$native_build_dir/bin/llvm-tblgen
-D LLVM_TARGET_ARCH=$BUILDER_ARCH
$BUILDER_EXTRA_CMAKE_FLAGS
EOF
)
  if ! [ "$BUILDER_OS" = 'macos' ]; then
    extra_cmake_flags="$extra_cmake_flags -D CMAKE_SYSROOT=$GITHUB_WORKSPACE/$BUILDER_TARGET_TRIPLE"
  fi
else
  export MACOSX_DEPLOYMENT_TARGET=10.9
  extra_cmake_flags="${BUILDER_EXTRA_CMAKE_FLAGS:-}"
fi

build_native() {
  ! [ "$BUILDER_CROSS_COMPILE" = true ] && return

  mkdir -p "$native_build_dir"
  pushd "$native_build_dir"

  cmake -G Ninja "$llvm_dir" $base_cmake_flags
  cmake --build . --target llvm-config llvm-tblgen clang-tblgen

  popd
}

build() {
  mkdir -p "$build_dir"
  pushd "$build_dir"

  cmake "$llvm_dir" \
    -G Ninja \
    $base_cmake_flags \
    -DLIBCLANG_BUILD_STATIC=On \
    $extra_cmake_flags

  cmake --build .
  popd
}

# Need to cleanup temporary files otherwise there's risk of running out of disk
# space on GitHub actions runners.
cleanup() {
  find \
    "$build_dir" \
    -type f \
    \( -iname '*.o' -or -iname '*.obj' \) \
    -delete

  rm -rf "$native_build_dir"
}

# Cannot do a proper install because there's risk of running out of disk space
# on GitHub actions runners. A proper install would mean duplicating files
# resulting in more disk space being used.
install() {
  mkdir -p "$build_dir/include"
  cp -r "$clang_dir/include/clang-c" "$build_dir/include"
}

archive() {
  if [ "$(host_os)" = 'windows' ]; then
    local command="7z a $(archive_name)"
  else
    local command="tar -c -J -f $(archive_path)"
  fi

  local libraries="$(find $install_name/lib \( -name '*.lib' -or -name '*.a' -or -name '*clang.so*' -or -name '*clang.dll*' -or -name '*clang.dylib' \) -maxdepth 1 -print0 | xargs -0)"
  local headers="$(find $install_name/include/clang-c -name '*.h' -print0 | xargs -0)"
  local binaries="$(find $install_name/bin -name 'llvm-config*' -print0 | xargs -0)"

  ls -l "$install_name/lib/clang"
  $command $libraries $headers $binaries "$install_name/lib/clang"
}

arch() {
  uname -m
}

host_os() {
  local host_os=$(uname | tr '[:upper:]' '[:lower:]')

  if [ "$host_os" = 'darwin' ]; then
    echo 'macos'
  elif grep -q 'mingw' <<< "$host_os" ; then
    echo 'windows'
  else
    echo "$host_os"
  fi
}

release_name() {
  echo "llvm-$version-$BUILDER_OS-$BUILDER_ARCH"
}

archive_name() {
  if [ "$(host_os)" = 'windows' ]; then
     local extension='7z'
  else
    local extension='tar.xz'
  fi

  echo "$(release_name).$extension"
}

archive_path() {
  echo "$GITHUB_WORKSPACE/$(archive_name)"
}

build_native
build
cleanup
install
archive
