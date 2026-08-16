#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
deps_root=${AXIA_DEPS_ROOT:-}
version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",/\1/p' "${repo_dir}/build.zig.zon")
architecture=$(uname -m)
fedora_version=${AXIA_FEDORA_VERSION:-$(rpm -E %fedora 2>/dev/null || true)}
package_name="axia-video-stabilize-${version}-fedora${fedora_version}-${architecture}"
dist_dir="${repo_dir}/dist"
archive_path="${dist_dir}/${package_name}.tar.gz"
checksum_path="${archive_path}.sha256"

if [[ -z "${version}" ]]; then
    echo "erro: não foi possível ler a versão de build.zig.zon" >&2
    exit 1
fi
if [[ -z "${deps_root}" ]]; then
    echo "erro: informe a raiz das dependências em AXIA_DEPS_ROOT" >&2
    exit 1
fi
if [[ -z "${fedora_version}" || "${fedora_version}" == "%fedora" ]]; then
    echo "erro: não foi possível identificar a versão do Fedora" >&2
    exit 1
fi

for command_name in zig ldd tar gzip sha256sum; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "erro: o comando '${command_name}' é necessário para gerar o pacote" >&2
        exit 1
    fi
done

include_dir="${deps_root}/include"
ffmpeg_include_dir="${include_dir}/ffmpeg"
opencv_include_dir="${include_dir}/opencv4"
lib_dir="${deps_root}/lib64"
for required_dir in "${ffmpeg_include_dir}" "${opencv_include_dir}" "${lib_dir}"; do
    if [[ ! -d "${required_dir}" ]]; then
        echo "erro: diretório de dependências ausente: ${required_dir}" >&2
        exit 1
    fi
done
build_args=(
    -Doptimize=ReleaseFast
    "-Dffmpeg-include=${ffmpeg_include_dir}"
    "-Dffmpeg-lib=${lib_dir}"
    "-Dopencv-include=${opencv_include_dir}"
    "-Dopencv-lib=${lib_dir}"
)

cd -- "${repo_dir}"
temporary_dir=$(mktemp -d)
trap 'rm -rf -- "${temporary_dir}"' EXIT
build_prefix="${temporary_dir}/build"
zig build --prefix "${build_prefix}" "${build_args[@]}"

package_dir="${temporary_dir}/${package_name}"
mkdir -p -- \
    "${package_dir}/lib/flexiblas" \
    "${package_dir}/libexec" \
    "${package_dir}/licenses"

install -m 0755 "${build_prefix}/bin/axia-video-stabilize" "${package_dir}/libexec/"
install -m 0755 "${build_prefix}/bin/axia-cli" "${package_dir}/libexec/"
install -m 0755 scripts/linux/axia-video-stabilize "${package_dir}/"
install -m 0755 scripts/linux/axia-cli "${package_dir}/"
install -m 0644 README.md "${package_dir}/"
install -m 0644 src/assets/fonts/OFL.txt "${package_dir}/licenses/Montserrat-OFL.txt"

runtime_library_path="${deps_root}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

ldd_output=$(LD_LIBRARY_PATH="${runtime_library_path}" \
    ldd "${build_prefix}/bin/axia-video-stabilize")
if grep -q 'not found' <<<"${ldd_output}"; then
    echo "erro: a build possui bibliotecas não resolvidas:" >&2
    grep 'not found' <<<"${ldd_output}" >&2
    exit 1
fi

while IFS= read -r library_path; do
    [[ -n "${library_path}" ]] || continue
    install -m 0755 "${library_path}" "${package_dir}/lib/$(basename -- "${library_path}")"
done < <(
    awk '/=> \/.*\.so/ { print $3 }' <<<"${ldd_output}" |
        awk -v prefix="${deps_root}/" 'index($0, prefix) == 1' |
        sort -u
)

flexiblas_dir="${deps_root}/lib64/flexiblas"
for flexiblas_library in libflexiblas_fallback_lapack.so libflexiblas_netlib.so; do
    if [[ ! -f "${flexiblas_dir}/${flexiblas_library}" ]]; then
        echo "erro: módulo FlexiBLAS ausente: ${flexiblas_library}" >&2
        exit 1
    fi
    install -m 0755 \
        "${flexiblas_dir}/${flexiblas_library}" \
        "${package_dir}/lib/flexiblas/"
done

if [[ -d "${deps_root}/share/licenses" ]]; then
    mkdir -p -- "${package_dir}/licenses/native"
    cp -a "${deps_root}/share/licenses/." "${package_dir}/licenses/native/"
fi

mkdir -p -- "${dist_dir}"
tar --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH:-0}" \
    --owner=0 --group=0 --numeric-owner \
    -C "${temporary_dir}" -cf - "${package_name}" |
    gzip -n >"${archive_path}"

(
    cd -- "${dist_dir}"
    sha256sum "$(basename -- "${archive_path}")" >"$(basename -- "${checksum_path}")"
)

verify_dir=$(mktemp -d)
trap 'rm -rf -- "${temporary_dir}" "${verify_dir}"' EXIT
tar -xzf "${archive_path}" -C "${verify_dir}"
verified_package_dir="${verify_dir}/${package_name}"
packaged_ldd=$(LD_LIBRARY_PATH="${verified_package_dir}/lib" \
    ldd "${verified_package_dir}/libexec/axia-video-stabilize")
if grep -q 'not found' <<<"${packaged_ldd}"; then
    echo "erro: o pacote possui bibliotecas não resolvidas:" >&2
    grep 'not found' <<<"${packaged_ldd}" >&2
    exit 1
fi
if grep -Fq "${deps_root}/" <<<"${packaged_ldd}"; then
    echo "erro: o pacote ainda depende da árvore usada durante a build" >&2
    exit 1
fi
env -u LD_LIBRARY_PATH "${verified_package_dir}/axia-cli" --version

echo "pacote: ${archive_path}"
echo "checksum: ${checksum_path}"
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "aviso: instale ffmpeg no Fedora para preview e conversão de áudio não-AAC" >&2
fi
