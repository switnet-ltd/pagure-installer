# Pagure Installer - Celery - Beta
Bash installer for Pagure on *buntu LTS 16.04 based systems such as trisquel 8.
New support for ubuntu 18.04

**Please note that this is a work in progress, not production ready**

## Features
* Support several instances at once by using a sufix
* Custom redis by instance by [mured.sh](https://github.com/switnet-ltd/mured)
    * Custom redis db for celery
* systemd pagure worker
    * python3
* systemd gitolite worker
    * gitolite3
* apache/letsencrypt self configuration


## To Be Determined
* set/fix workers configuration
* more TBD

## Requirements
* *buntu 18.04 (new)
* *buntu 16.04 / Trisquel 8
    * requires backport libgit2 v0.26
* At least 1 domain configured, in order to use ssl along with letsencrypt
* more TBD


SwITNet Ltd © - 2018, https://switnet.net/
