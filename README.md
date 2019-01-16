# Pagure Installer - Celery - Beta
Bash installer for Pagure on *buntu LTS 16.04 based systems such as trisquel 8.
New support for ubuntu 18.04

**Please note that this is a work in progress, not production ready**

## Features
* Custom redis for instance or celery by [mured.sh](https://github.com/switnet-ltd/mured)
* systemd pagure worker - python3
* systemd gitolite worker - gitolite3
* jenkins integration (testing)
* apache/letsencrypt self configuration


## To Be Determined
* set/fix workers configuration
* see [issues.](https://pagure.io/pagure-installer-trisquel/issues)

## Requirements
* Any of the following distros.
    * Trisquel 8
    * Ubuntu 18.04
    * Ubuntu 16.04
        * requires backport libgit2 v0.26
* At least 1 domain configured, in order to use ssl along with letsencrypt


SwITNet Ltd © - 2018, https://switnet.net/
