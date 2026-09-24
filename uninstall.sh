#!/usr/bin/env bash
# Remove the Omarchy Touch Bar daemon and leave tiny-dfr with a plain F-row.
set -euo pipefail

# NixOS keeps no /usr/bin; resolve tools from the system profile or FHS paths
# before falling back to PATH.
find_tool () {
  local name=$1 path
  for path in /run/current-system/sw/bin /usr/local/sbin /usr/local/bin \
              /usr/sbin /usr/bin /sbin /bin; do
    if [[ -x $path/$name ]]; then
      printf '%s\n' "$path/$name"
      return 0
    fi
  done
  if path=$(command -v "$name" 2>/dev/null); then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

systemctl=$(find_tool systemctl || true)
systemctl=${systemctl:-systemctl}
rm=$(find_tool rm || true)
rm=${rm:-rm}
sed=$(find_tool sed || true)
sed=${sed:-sed}

user_bin="${HOME}/.local/bin"
omarchy_config="${HOME}/.config/omarchy"
hypr_config="${HOME}/.config/hypr"
user_systemd="${HOME}/.config/systemd/user"

"$systemctl" --user disable --now omarchy-touchbar.service 2>/dev/null || true
"$rm" -f "$user_systemd/omarchy-touchbar.service"
"$systemctl" --user daemon-reload

"$rm" -f "$user_bin/omarchy-touchbar" "$user_bin/omarchy-chatgpt-dictate" \
  "$user_bin/omarchy-touchbar-settings" \
  "${HOME}/.local/share/applications/omarchy-touchbar-settings.desktop" \
  "$omarchy_config/hooks/theme-set.d/touchbar" \
  "$omarchy_config/touchbar.toml.dist"

autostart="$hypr_config/autostart.lua"
if [[ -f $autostart ]]; then
  "$sed" -i '/Context-aware T2 MacBook Touch Bar/d;/omarchy-touchbar/d' "$autostart"
fi

echo "Touch Bar daemon removed. Kept: ~/.config/omarchy/touchbar.toml and the"
echo "sudo-installed pieces (/etc/tiny-dfr, udev rule, touchbar-panel-reset)."
echo "Remove those with:"
echo "  sudo systemctl disable --now touchbar-panel-reset.service"
echo "  sudo rm -f /etc/systemd/system/touchbar-panel-reset.service /usr/local/lib/touchbar-panel-reset /etc/udev/rules.d/99-touchbar-backlight.rules"
if [[ -d /run/current-system ]]; then
  echo
  echo "On NixOS the system pieces come from nixos/touchbar.nix instead: drop"
  echo "that import from configuration.nix and nixos-rebuild switch."
fi
