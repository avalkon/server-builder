# server-builder

Script to fully set up a Mint or Ubuntu server with apache, samba, tailscale, searxng, calibre-web-nextgen, crosspoint-sync, and navidrome.

# How to use

To use, simply download, set as executable, and execute using the relevant commands to install, reinstall, or uninstall one or more or all services.

 # Usage Examples:
   sudo ./server-install.sh --install_all          # Full installation (silent)
   sudo ./server-install.sh -v --install_all       # Full installation (verbose)
   sudo ./server-install.sh --install-sync         # Only CrossPoint Sync
   sudo ./server-install.sh --uninstall-navidrome  # Only Uninstall Navidrome
   sudo ./server-install.sh -v --uninstall-all     # Uninstall everything (verbose)

# Installation Modes:
    --install-all                Install everything
    --reinstall                  Reinstall/repair all managed services without deleting libraries

# Selective Installation:
    --install-sharing            Install file sharing (Samba, Tailscale, Nemo)
    --install-web                Install web server (Apache + PHP)
    --install-searxng            Install SearxNG search engine
    --install-calibre            Install Calibre-Web NextGen (includes Calibre)
    --install-sync               Install CrossPoint Sync only
    --install-navidrome          Install Navidrome music server only

# Uninstallation Modes:
    --uninstall-all              Remove all managed services and packages
    --uninstall-sharing          Remove Samba, Tailscale, Nemo
    --uninstall-web              Remove Apache + PHP
    --uninstall-searxng          Remove SearxNG
    --uninstall-calibre          Remove Calibre-Web (keeps library)
    --uninstall-sync             Remove CrossPoint Sync
    --uninstall-navidrome        Remove Navidrome

# Utility Commands:
    --status                     Show status of all services
    --help,-h                    Show the help message

# NOTES:
  - All operations require root privileges
  - Most services are independent; order matters for dependencies; searxng relies on apache in this script and cannot run without it. Apache does not rely on searxng.
  - Personal library files and some settings files are preserved during uninstallation
  - Uninstallation does not remove apt packages in case of other dependencies. You can run apt autoremove afterwords if you want.
