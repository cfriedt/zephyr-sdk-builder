```
usage:
build-sdk.sh [options..] [commands...]

Many options can be specified additively times. To list all
arguments supported by a specific option, use e.g.
'--target list'.

options:
<-a|--patch-dir> dir            patch sdk-ng from 'dir'
                                Default: $PWD
<-d|--dry-run>                  Do not do anything. Just print steps
<-h|--help>                     Print usage information
<-k|--sdk-version>    version   Build Zephyr SDK 'version'
                                Default: 0.15.2
<-l|--poky-downloads> dir       Save Poky (Yocto) downloads in 'dir'
                                Default: $HOME/build-zephyr-sdk/poky-downloads
<-m|--temp>           dir       Use 'dir' as the temporary directory
                                Default: $HOME/build-zephyr-sdk
<-n|--no-deps>                  Do not install dependencies
<-p|--python-version> version   Use the specified python version
                                Default: python3.8
<-s|--host>           host      Build the SDK for 'host'
                                Default: all
<-t|--target>         target    Build a toolchain for 'target'
                                Default: all
<-x|--proxy>          proxy     Use 'proxy' as the proxy
                                Default: 
<-y|--yes>                      Automatically answer 'yes' when prompted
                                Default: 

commands (the default is to execute all commands):
deps                  install RPM dependencies via dnf
clean                 clean the temp directory
prepare               check out and patch sources
manifest              generate the build matrix
build                 build all targets specified via the build matrix
hosttools             build host tools

#################################################################
# NOTE: the build process uses wget. If you use a proxy, please
# ensure that the relevant parameters are included in /etc/wgetrc
# or ~/.wgetrc
#################################################################
```
