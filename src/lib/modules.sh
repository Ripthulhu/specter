# shellcheck shell=sh

_module_name() {
  _mn_file="$1"
  while IFS='=' read -r _mn_key _mn_val; do
    if [ "$_mn_key" = "name" ]; then
      printf '%s\n' "$_mn_val"
      break
    fi
  done < "$_mn_file"
  unset _mn_file _mn_key _mn_val
  return 0
}

module_detect() {
  _md_id="$1"
  for _md_dir in "$MODULES_BASE/$_md_id" "${MODULES_BASE}_update/$_md_id"; do
    [ -f "$_md_dir/module.prop" ] || continue
    _module_name "$_md_dir/module.prop"
    unset _md_id _md_dir
    return 0
  done
  unset _md_id _md_dir
  return 1
}

module_enabled() {
  _me_id="$1"
  _me_dir="$MODULES_BASE/$_me_id"
  [ -f "$_me_dir/module.prop" ] || _me_dir="${MODULES_BASE}_update/$_me_id"
  [ -f "$_me_dir/module.prop" ] || { unset _me_id _me_dir; return 1; }
  [ -f "$_me_dir/disable" ] && { unset _me_id _me_dir; return 1; }
  _module_name "$_me_dir/module.prop"
  unset _me_id _me_dir
  return 0
}

module_disable() {
  _mdi_id="$1"
  for _mdi_dir in "$MODULES_BASE/$_mdi_id" "${MODULES_BASE}_update/$_mdi_id"; do
    [ -f "$_mdi_dir/module.prop" ] || continue
    [ -f "$_mdi_dir/disable" ] && continue
    touch "$_mdi_dir/disable" 2>/dev/null || true
  done
  unset _mdi_id _mdi_dir
}

install_module_from_github() {
  _mg_repo="$1"
  _mg_name="${2:-$_mg_repo}"

  [ -n "$ROOT_SOL" ] || detect_root_solution
  check_network 2>/dev/null || return 1

  _mg_json=$(download "https://api.github.com/repos/${_mg_repo}/releases/latest" "" 2>/dev/null) || return 1

  _mg_dex="${SPECTER_DEX:-${MODDIR%/features}/deps/classes.dex}"
  _mg_asset=$(printf '%s' "$_mg_json" | CLASSPATH="$_mg_dex" app_process / com.dpejoh.specter.ReleaseAsset "$_mg_repo") || return 1
  _mg_dl_url="${_mg_asset%%|*}"
  _mg_sha256="${_mg_asset#*|}"

  _mg_tmp="/data/local/tmp/.mg_install_$$.zip"
  download "$_mg_dl_url" "$_mg_tmp" "$_mg_sha256" 2>/dev/null || {
    rm -f "$_mg_tmp"
    return 1
  }

  _mg_rc=1
  case "$ROOT_SOL" in
    magisk)  magisk --install-module "$_mg_tmp" >/dev/null 2>&1 && _mg_rc=0 ;;
    kernelsu) ksud module install "$_mg_tmp" >/dev/null 2>&1 && _mg_rc=0 ;;
    apatch)  apd module install "$_mg_tmp" >/dev/null 2>&1 && _mg_rc=0 ;;
  esac
  rm -f "$_mg_tmp"

  _mg_rc_final=$_mg_rc
  unset _mg_repo _mg_name _mg_json _mg_asset _mg_dex _mg_dl_url _mg_sha256 _mg_tmp _mg_rc
  return $_mg_rc_final
}
