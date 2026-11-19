#!/bin/bash
# Builds OpenTW: OpenMW 0.52 RC1 with the patches in opentw/patches
# (runtime terraforming). macOS on Apple Silicon; game only, no launcher
# or editor (those need Qt).
#
# Usage: tools/build_opentw.sh [work-dir]   (default: ../opentw next to this repo)
# Result: <work-dir>/build/OpenMW.app (run it like the normal OpenMW.app)
# Needs: Xcode command line tools and Homebrew (installs cmake and p7zip).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$ROOT/../opentw}"
TAG=openmw-52-rc1

command -v cmake >/dev/null || brew install cmake
command -v 7z >/dev/null || brew install p7zip

if [ ! -d "$WORK/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://gitlab.com/OpenMW/openmw.git "$WORK"
  git -C "$WORK" checkout -b opentw
  git -C "$WORK" -c user.name=OpenTW -c user.email=opentw@localhost am "$ROOT"/opentw/patches/*.patch
fi

# Prebuilt dependencies (OpenSceneGraph fork, Bullet, MyGUI, ...), the same
# bundle OpenMW's own macOS CI uses
DEPS="$WORK/.deps"
if [ ! -d "$DEPS/deps" ]; then
  mkdir -p "$DEPS"
  source "$WORK/CI/macos/deps_versions.sh"
  curl -fsSL "https://gitlab.com/OpenMW/openmw-deps/-/raw/main/macos/vcpkg-arm64-osx-dynamic-${VCPKG_TAG}-manifest.txt" -o "$DEPS/manifest.txt"
  { read -r URL && read -r HASH FILE; } < "$DEPS/manifest.txt"
  curl -fSL "$URL" -o "$DEPS/$FILE"
  echo "$HASH  $DEPS/$FILE" | shasum -a 512 -c
  7z x -y -o"$DEPS/pre" "$DEPS/$FILE" >/dev/null
  mv "$DEPS"/pre/*/ "$DEPS/deps"
  rmdir "$DEPS/pre"
fi
D="$DEPS/deps"

mkdir -p "$WORK/build"
cd "$WORK/build"
cmake .. -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_OSX_DEPLOYMENT_TARGET=14.8 \
  -DOPENMW_USE_SYSTEM_YAML_CPP=OFF \
  -DBUILD_OPENMW=ON -DBUILD_LAUNCHER=OFF -DBUILD_WIZARD=OFF -DBUILD_OPENCS=OFF \
  -DBUILD_ESMTOOL=OFF -DBUILD_BSATOOL=OFF -DBUILD_ESSIMPORTER=OFF -DBUILD_NIFTEST=OFF \
  -DBUILD_NAVMESHTOOL=OFF -DBUILD_BULLETOBJECTTOOL=OFF -DBUILD_MWINIIMPORTER=OFF \
  -DCMAKE_PREFIX_PATH="$D/installed/arm64-osx-dynamic" \
  -DVCPKG_HOST_TRIPLET=arm64-osx-dynamic -DVCPKG_TARGET_TRIPLET=arm64-osx-dynamic \
  -DCMAKE_TOOLCHAIN_FILE="$D/scripts/buildsystems/vcpkg.cmake"
make -j"$(sysctl -n hw.ncpu)" openmw
# Finder caches app bundles: make it see the fresh one
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$WORK/build/OpenMW.app" || true
echo "Built: $WORK/build/OpenMW.app (open it from Finder or with: open \"$WORK/build/OpenMW.app\")"
