# Pagure Installer - Celery - Beta
Bash installer for Pagure on Ubuntu LTS based systems such as Trisquel 8.

**Please note that this is a work in progress, not production ready**

## Features
* Installation of pagure latest stable release
* Custom redis for instance or celery by [mured.sh](https://github.com/switnet-ltd/mured)
* Systemd pagure worker - python3
* Systemd gitolite worker - gitolite3
* Jenkins integration (testing)
* Apache/letsencrypt self configuration

## Requirements
* Any of the following distros.
    * Trisquel 8
    * Ubuntu 18.04
    * Ubuntu 16.04
        * requires backport libgit2 v0.26
* At least 1 domain configured, in order to use ssl along with letsencrypt

## Feedback
* improve workers configuration
* see [issues.](https://pagure.io/pagure-installer-trisquel/issues)

SwITNet Ltd © - 2018, https://switnet.net/
