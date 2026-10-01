# server-builder

Script to fully set up a Mint or Ubuntu server with apache, samba, tailscale, searxng, calibre-web-nextgen, crosspoint-sync, and navidrome. 
Nemo is in the script, but commented out, uncomment it if you would like it. Nemo is not necessary for file sharing.
Does not invoke Docker, ever. Fully bare-metal Mint/Ubuntu.

# How to use

To use, simply download, set as executable(chmod +x ./server-install.sh), and execute using the relevant commands to install, reinstall, or uninstall one or more or all services. The installer will prompt you for paths to your library and music, along with your domain(example.com), sitename(the filename apache uses for your config files, anything but 000-default), and subdomain(optional)

# OPTIONS:
  Installation Modes:
  
    (no args)                    Show this help message
    
    --install-all                Run complete installation of all services
    
    --reinstall                  Reinstall/repair all managed services without deleting libraries

  Selective Installation:
  
    --install-sharing            Install file sharing (Samba, Tailscale, (Nemo if uncommented))
    
    --install-web                Install web server (Apache + PHP)
    
    --install-searxng            Install SearxNG search engine(requires Apache)
    
    --install-calibre            Install Calibre-Web-NextGen--no-docker (also installs the most recent Calibre)
    
    --install-sync               Install CrossPoint Sync only
    
    --install-navidrome          Install Navidrome music server only

  Uninstallation Modes:
  
    --uninstall-all              Remove all managed services and packages
    
    --uninstall-sharing          Remove Samba, Tailscale, Nemo
    
    --uninstall-web              Remove Apache + PHP
    
    --uninstall-searxng          Remove SearxNG
    
    --uninstall-calibre          Remove Calibre-Web (keeps library)
    
    --uninstall-sync             Remove CrossPoint Sync
    
    --uninstall-navidrome        Remove Navidrome


  Utility Commands:
  
    --status                     Show status of all services
    
    --help,-h                    Show this help message

  Verbosity:
  
    -v, --verbose                Show every command being executed
    
    -s, --silent                 Minimal output (default)

# EXAMPLES:
| Command | Effect |
|---|---|
|  sudo ./server-install.sh                             | # Show help|
|  sudo ./server-install.sh -v                          | # Show help|
|  sudo ./server-install.sh --install-all               | # Full installation|
|  sudo ./server-install.sh -v --install-all            | # Full installation (verbose)|
|  sudo ./server-install.sh -v --install-sync           | # Install CrossPoint Sync verbosely|
|  sudo ./server-install.sh --uninstall-navidrome       | # Remove Navidrome only|
|  sudo ./server-install.sh --uninstall-all             | # Remove everything|
|  sudo ./server-install.sh -v --status                 | # Check service status verbosely|

# NOTES:
  - All operations require root privileges
  - Most services are independent; order matters for dependencies; searxng relies on apache in this script and cannot run without it. Apache does not rely on searxng.
  - Personal library files and some settings files are preserved during uninstallation
  - Uninstallation does not remove apt packages in case of other dependencies. You can run apt autoremove afterwords if you want.
  - Auto-ingest should run without extra work on non-docker installs of calibre-web-nextgen.
