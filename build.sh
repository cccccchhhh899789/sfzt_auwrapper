#!/bin/bash
# sfzt_auwrapper dlopen 版构建脚本（本机 Intel 直编，无需 Xcode）
# 用法: ./build.sh <VST3路径> <输出.component> [Name] [AUtype] [subtype] [manuf]
set -e
VST3="${1:?用法: build.sh <vst3绝对路径> <out.component> [Name] [aumu|aufx] [subtype] [manuf]}"
OUT="${2:?需要输出 .component 路径}"
NAME="${3:-$(basename "$VST3" .vst3)}"
AUTYPE="${4:-aumu}"
SUBTYPE="${5:-SFZW}"
MANUF="${6:-SFZW}"
SDKROOTDIR="${SDKROOT:-/tmp/ausdk}"
S="$SDKROOTDIR/vst3sdk-3.7.10_build_14"
CA="$SDKROOTDIR/CoreAudio/CoreAudio"
SRC="$(cd "$(dirname "$0")" && pwd)"
SDKP="$(xcrun --show-sdk-path)"

# 生成 ObjC 类前缀（防多包符号冲突）。用 subtype 保证每个包唯一（时间戳会同秒相撞）
printf '#define SMTG_AU_NAMESPACE\tSFZW%s_\n' "$SUBTYPE" > "$SRC/aucocoaclassprefix.h"

INCS=(-I"$SRC" -I"$S")
while IFS= read -r d; do INCS+=(-I"$d"); done < <(find "$CA" "$S/base" "$S/pluginterfaces" "$S/public.sdk/source" -type d)

FLAGS=(-x objective-c++ -std=c++17 -mmacosx-version-min=10.13 -DNDEBUG -DRELEASE
       -isysroot "$SDKP" -nostdinc++ -isystem "$SDKP/usr/include/c++/v1"
       -Wno-deprecated-declarations -Wno-parentheses -Wno-unused-value
       -Wno-overloaded-virtual -Wno-multichar -Wno-non-virtual-dtor -Wno-reorder-ctor
       -Wno-inconsistent-missing-override -Wno-c++11-narrowing -Wno-invalid-noreturn
       -Wno-return-type -Wno-format -Wno-implicit-function-declaration
       -Wno-int-to-pointer-cast -Wno-non-pod-varargs -Wno-unused-private-field
       -Wno-switch -Wno-null-dereference)

BUILD="$SRC/build-tmp-$SUBTYPE"; mkdir -p "$BUILD"
OBJS=()
compile() { # file quiet?
  local f="$1" quiet="${2:-0}"
  local o="$BUILD/$(echo "${f#$SRC/}" | tr '/.' '__').o"
  if [ -f "$o" ] && [ "$o" -nt "$f" ]; then OBJS+=("$o"); return 0; fi
  if [ "$quiet" = 1 ]; then
    clang "${FLAGS[@]}" "${INCS[@]}" -c "$f" -o "$o" 2>/dev/null && OBJS+=("$o") || echo "  skip: $(basename "$f")"
  else
    clang "${FLAGS[@]}" "${INCS[@]}" -c "$f" -o "$o" && OBJS+=("$o")
  fi
}

echo "[1/4] wrapper 源…"
compile "$SRC/auwrapper.mm"
compile "$SRC/aucocoaview.mm"
compile "$SRC/ausdk.mm"          # 聚合 import 全部 CoreAudio AU 公共类
compile "$SRC/NSDataIBStream.mm"

echo "[2/4] VST3 SDK base/hosting…"
for f in "$S/base/source/"*.cpp "$S/base/thread/source/"*.cpp; do compile "$f" 1; done
for f in "$S/public.sdk/source/vst/hosting/"*.cpp; do
  case "$(basename "$f")" in *hostdataexchangehandler*) continue;; esac   # 与 vstinitiids 重复定义 iid，官方 auwrapper 源清单亦不含它
  compile "$f" 1
done
for f in "$S/public.sdk/source/vst/utility/stringconvert.cpp" "$S/public.sdk/source/common/commoniids.cpp" "$S/public.sdk/source/common/memorystream.cpp" "$S/public.sdk/source/common/pluginview.cpp"; do compile "$f" 1; done
compile "$S/public.sdk/source/common/threadchecker_mac.mm"
compile "$S/public.sdk/source/vst/vstinitiids.cpp" 1
compile "$S/pluginterfaces/base/funknown.cpp" 1
compile "$S/pluginterfaces/base/ustring.cpp" 1
compile "$S/pluginterfaces/base/coreiids.cpp" 1

echo "[3/4] 链接 ${#OBJS[@]} 个目标文件…"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
clang++ -dynamiclib -mmacosx-version-min=10.13 -all_load -Wl,-dead_strip \
  -o "$OUT/Contents/MacOS/$NAME" "${OBJS[@]}" \
  -framework AudioToolbox -framework CoreAudio -framework CoreMIDI \
  -framework CoreFoundation -framework Cocoa

echo "[4/4] Info.plist + 签名…"
sed -e "s|SFZWEXEC|$NAME|g" -e "s|SFZWPATH|$VST3|g" -e "s|SFZWTYPE|$AUTYPE|g" \
    -e "s|SFZWSUB|$SUBTYPE|g" -e "s|SFZWMANUF|$MANUF|g" -e "s|SFZWNAME|$NAME|g" \
    "$SRC/Info.plist.template" > "$OUT/Contents/Info.plist"
chmod -R go+rX "$OUT"
codesign --force --sign - "$OUT"
echo "DONE: $OUT"
"$SRC/verify.sh" "$OUT" "$NAME" 2>/dev/null || true
