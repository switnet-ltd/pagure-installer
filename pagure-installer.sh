#!/bin/bash
# Pagure (multi) installer - *buntu 16.04 based.
# SwITNet Ltd © - 2018, https://switnet.net/
# GPLv3 or later.
DIST=$(lsb_release -sc)
#Check if user is root
if ! [ $(id -u) = 0 ]; then
   echo "You need to be root or have sudo privileges!"
   exit 1
fi
if [ $DIST = bionic ]; then
add-apt-repository universe
fi
echo "#--------------------------------------------------
# Checking and installing system dependancies...
#--------------------------------------------------"
apt -qq update && \
apt -yqq install \
				apt-utils \
				curl \
				dialog \
				gcc \
				git \
				libffi-dev \
				libgit2-dev \
				libjpeg-dev \
				python3-gdbm \
				python3-jinja2 \
				python3-pip \
				python3-psycopg2 \
				python3-venv \
				virtualenv \
				redis-server

echo "gitolite3 gitolite3/adminkey string " | debconf-set-selections
apt -yqq install gitolite3

PGSV=$(apt-cache madison postgresql | head -n1 | awk '{print $3}' | cut -d "+" -f1)
PYT_V=$(apt-cache madison python3 | head -n1 | awk '{print $3}' | cut -d "." -f1,2)
install_ifnot() {
if [ "$(dpkg-query -W -f='${Status}' $1 2>/dev/null | grep -c "ok installed")" == "1" ]; then
	echo " $1 is installed, skipping..."
    else
    	echo -e "\n---- Installing $1 ----"
		apt -yqq install $1
fi
}
check_empty_sed() {
if [[ -z "$4" ]]; then
	echo "Empty $1 variable, leaving default"
else
	sed -i "$(grep -n $1 $2 | head -n 1 | cut -d ":" -f1) s|$3|$4|" $2
fi
}
first_nline_patter() {
grep -n $1 $2 | cut -d ":" -f1 | head -n1
}
#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
install_ifnot language-pack-en-base
install_ifnot postgresql-$PGSV

#Enable jenkins?
while [[ $jenkins != yes && $jenkins != no ]]
do
read -p "Do you want to enable jenkins?: (yes or no)"$'\n' -r jenkins
if [ $jenkins = no ]; then
	echo "Jenkins won't be enable"
elif [ $jenkins = "yes" ]; then
	echo "Jenkins will be enabled"
fi
done
PAG_ID="pagure"
PAG_USER="git"
PAG_PDB="${PAG_USER}_db"
SHUF=$(shuf -i 15-19 -n 1)
PDB_PASS=$(tr -dc "a-zA-Z0-9@#*=" < /dev/urandom | fold -w "$SHUF" | head -n 1)
PAG_HOME="/home/$PAG_USER"
PAG_HOME_EXT="$PAG_HOME/${PAG_ID}-server"
HOOK_RUNR="$PAG_HOME_EXT/pagure/hooks/files/hookrunner"
PY_VENV_DIR="/home/$PAG_USER/.venv"
PAG_USR_SHARE="/usr/share/pagure"
PAG_CFG_DIR="/etc/pagure"
PAG_CFG_FILE="/etc/pagure/pagure.cfg"
LOG_DIR="/var/log/pagure"
LOG_FILE="/var/log/pagure/pagure-server.log"
PAG_WRK_SRV="/lib/systemd/system/${PAG_ID}_worker.service"
PAG_GIT_WRK="/lib/systemd/system/${PAG_ID}_gitolite.service"
PAG_CI_WRK="/lib/systemd/system/${PAG_ID}_ci.service"
PAG_EV_WRK="/lib/systemd/system/${PAG_ID}_ev.service"
ADDRESS=$(hostname -I | cut -d ' ' -f 1)
CERTBOT_REPO=$(apt-cache policy | grep http | grep certbot | head -n 1 | awk '{print $2}' | cut -d "/" -f 5)
if [ $DIST = xenial ]; then
#Tmp fix for getting backported libraries
wget \
https://ark.switnet.org/tmp/libgit2/libgit2-26_0.26.0+dfsg.1-1.1ubuntu0.2_amd64.deb \
https://ark.switnet.org/tmp/libgit2/libgit2-dev_0.26.0+dfsg.1-1.1ubuntu0.2_amd64.deb
dpkg -i libgit2*.deb
apt install -fy
apt -y autoremove
rm -rf libgit2*.deb
fi
if [ $DIST = flidas ]; then
DIST="xenial"
fi
set_ssl_apache() {
SSL_UP=$(grep -n $1 $2 | cut -d ':' -f1)
SSL_DWN=$((SSL_UP + 12))
CERT_CRT="/etc/letsencrypt/live/$3/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/$3/privkey.pem"
sed -i "$SSL_UP,$SSL_DWN s|.*SSLCertificateFile.*|SSLCertificateFile $CERT_CRT|" $2
sed -i "$SSL_UP,$SSL_DWN s|.*SSLCertificateKeyFile.*|SSLCertificateKeyFile $CERT_KEY|" $2
}
update_certbot() {
	if [ "$CERTBOT_REPO" = "certbot" ]; then
	echo "
Cerbot repository already on the system!
Checking for updates...
"
	apt -qq update
	apt -yqq dist-upgrade
else
	echo "
Adding cerbot (formerly letsencrypt) PPA repository for latest updates
"
	echo "deb http://ppa.launchpad.net/certbot/certbot/ubuntu $DIST main" > /etc/apt/sources.list.d/certbot.list
	apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 75BCA694
	apt -qq update
	apt -yqq install letsencrypt
fi
}
#--------------------------------------------------
# Create Postgresql user
#--------------------------------------------------
echo -e "\n---- Creating the Pagure PostgreSQL User  ----"
cd /tmp
sudo -u postgres psql <<DB
CREATE DATABASE ${PAG_PDB};
CREATE USER ${PAG_ID} WITH ENCRYPTED PASSWORD '${PDB_PASS}';
GRANT ALL PRIVILEGES ON DATABASE ${PAG_PDB} TO ${PAG_ID};
DB
service postgresql restart

#--------------------------------------------------
# System Settings
#--------------------------------------------------
echo -e "\n---- Creating $PAG_USER system user ----"
adduser --system --quiet --shell=/bin/bash --home=$PAG_HOME --gecos 'Pagure' --group $PAG_USER
usermod -a -G www-data $PAG_USER
echo -e "\n---- Creating log directory ----"
mkdir $LOG_DIR $PAG_CFG_DIR $PAG_USR_SHARE
chown $PAG_USER:$PAG_USER $LOG_DIR $PAG_CFG_DIR $PAG_USR_SHARE

#Retrieve the sources
cd $PAG_HOME
sudo su $PAG_USER -c "git clone --depth 1 https://pagure.io/pagure.git $PAG_HOME_EXT/"
sed -i "s|.*sys.path.insert.*|sys.path.insert(0, \'$PAG_HOME_EXT\')|" $HOOK_RUNR
#Keep for verbose config.
sed -i "s|/etc/pagure/pagure.cfg|$PAG_CFG_FILE|g" $HOOK_RUNR
echo -e "\n---- Installing python (pip) dependacies for pagure ----"
sudo su $PAG_USER -c "mkdir $PY_VENV_DIR"
sudo su $PAG_USER -c "virtualenv --system-site-packages -p python3 $PY_VENV_DIR"
sudo su $PAG_USER -c "source $PY_VENV_DIR/bin/activate"
sudo su $PAG_USER -c "$PY_VENV_DIR/bin/pip3 install --upgrade pip"
sudo su $PAG_USER -c "$PY_VENV_DIR/bin/pip3 install asyncio pygit2==0.26.4"
#sudo su $PAG_USER -c "$PY_VENV_DIR/bin/pip3 install psycopg2 idna==2.7 pygit2==0.26.4"
sudo su $PAG_USER -c "$PY_VENV_DIR/bin/pip3 install -r $PAG_HOME_EXT/requirements.txt"
#Create the folder that will receive the projects, forks, docs, requests and tickets' git repo
sudo su $PAG_USER -c "mkdir -p $PAG_HOME/.gitolite/{conf,keydir,logs}"
sudo su $PAG_USER -c "mkdir -p $PAG_HOME/{repositories,attachments,remotes,releases}"
sudo su $PAG_USER -c "mkdir -p $PAG_HOME/repositories/{docs,forks,requests,tickets}"
#Add empty gitolite
sudo su $PAG_USER -c "touch $PAG_HOME/.gitolite/conf/gitolite.conf"
#Setup config files
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/gitolite3.rc $PAG_HOME/.gitolite.rc"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/pagure.cfg.sample $PAG_CFG_FILE"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/alembic.ini $PAG_CFG_DIR/alembic.ini"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/pagure.wsgi $PAG_USR_SHARE/pagure.wsgi"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/doc_pagure.wsgi $PAG_USR_SHARE/doc_pagure.wsgi"

#ToDo - Check usage
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/aclchecker.py $PAG_HOME/aclchecker.py"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/keyhelper.py $PAG_HOME/keyhelper.py"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/api_key_expire_mail.py $PAG_HOME/api_key_expire_mail.py"
#Fix shebang for several scripts (pagure.spec)
sed -e "s|#\!/usr/bin/env python|#\!${PY_VENV_DIR}/bin/python3|" -i \
    $PAG_HOME/aclchecker.py \
    $PAG_HOME/keyhelper.py \
    $PAG_HOME/api_key_expire_mail.py \
    $PAG_HOME_EXT/pagure/hooks/files/*.py \
    $HOOK_RUNR \
    $PAG_HOME_EXT/pagure/hooks/files/repospannerhook
#ToDo - Check usage
#sed -e "s|#!/usr/bin/env python|#!%{__python}|" -i \
#    $PAG_HOME_EXT/pagure-milters/comment_email_milter.py \


SKEY=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
SMAIL=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
sed -i "s|.*SECRET_KEY.*|SECRET_KEY=\'$SKEY\'|" $PAG_CFG_FILE
sed -i "s|.*SALT_EMAIL.*|SALT_EMAIL=\'$SMAIL\'|" $PAG_CFG_FILE
# DATA BASE
sed -i "s|DB_URL = 'sqlite|#DB_URL = 'sqlite|" $PAG_CFG_FILE
sed -i "$(first_nline_patter "postgres://" $PAG_CFG_FILE) s|#DB_URL|DB_URL|" $PAG_CFG_FILE
sed -i "$(first_nline_patter "postgres://" $PAG_CFG_FILE) s|user|$PAG_ID|" $PAG_CFG_FILE
sed -i "$(first_nline_patter "postgres://" $PAG_CFG_FILE) s|pass|$PDB_PASS|" $PAG_CFG_FILE
sed -i "$(first_nline_patter "postgres://" $PAG_CFG_FILE) s|host|localhost|" $PAG_CFG_FILE
sed -i "$(first_nline_patter "postgres://" $PAG_CFG_FILE) s|db_name|$PAG_PDB|" $PAG_CFG_FILE

#Enable and setup email
echo -e "\nDo you want to enable and configure email sending? (yes|no):"
while [[ $EMAIL_SET_ANS != yes && $EMAIL_SET_ANS != no ]]
do
	read EMAIL_SET_ANS
if [ $EMAIL_SET_ANS = no ]; then
	echo "If you change your mind, please configure it manually."
elif [ $EMAIL_SET_ANS = yes ]; then
	sed -i "s|.*EMAIL_SEND.*|EMAIL_SEND = True|" $PAG_CFG_FILE
	echo "Starting email setup"
		#EMAIL SETUP
		ADMIN_MAIL=""
		EMAIL_SYS_ERR=""
		SMTP_SRV=""
		SMTP_PORT=""
		SMTP_SSL=""
		SMTP_USR=""
		SMTP_PSWD=""
		NOTFY_EMAIL=""
		NOTFY_DOMAIN=""
		# Store data to $SETUP_EMAIL variable
		SETUP_EMAIL=$(\
		dialog --ok-label "Submit" \
				--backtitle "Pagure Mail Setup" \
				--title "Pagure - Mail Options" \
				--form "Set system values for email" \
		20 90 0 \
				"Admin user email:"						1 1	"$ADMIN_MAIL"	 	1 40 40 0 \
				"Email to receive traceback errors:"	2 1	"$EMAIL_SYS_ERR" 	2 40 40 0 \
				"Email used to send notifications:"		3 1	"$NOTFY_EMAIL" 		3 40 40 0 \
				"Mail domain notification (headers):"	4 1	"$NOTFY_DOMAIN" 	4 40 40 0 \
				"SMTP Server:"  						5 1	"$SMTP_SRV"  		5 40 40 0 \
				"SMTP SSL Port (465):"	   				6 1	"$SMTP_PORT"  		6 40 40 0 \
				"SMTP SSL (True|False):"				7 1	"$SMTP_SSL" 		7 40 40 0 \
				"SMTP Username:"						8 1	"$SMTP_USR" 		8 40 40 0 \
				"SMTP Password:"						9 1	"$SMTP_PSWD" 		9 40 40 0 \
		  3>&1 1>&2 2>&3 3>&- \
		)
		# Extract variables
		ADMIN_MAIL=$(echo "$SETUP_EMAIL" | sed -n 1p)
		EMAIL_SYS_ERR=$(echo "$SETUP_EMAIL" | sed -n 2p)
		NOTFY_EMAIL=$(echo "$SETUP_EMAIL" | sed -n 3p)
		NOTFY_DOMAIN=$(echo "$SETUP_EMAIL" | sed -n 4p)
		SMTP_SRV=$(echo "$SETUP_EMAIL" | sed -n 5p)
		SMTP_PORT=$(echo "$SETUP_EMAIL" | sed -n 6p)
		SMTP_SSL=$(echo "$SETUP_EMAIL" | sed -n 7p)
		SMTP_USR=$(echo "$SETUP_EMAIL" | sed -n 8p)
		SMTP_PSWD=$(echo "$SETUP_EMAIL" | sed -n 9p)

		# Set them in place
		check_empty_sed "PAGURE_ADMIN_USERS" "$PAG_CFG_FILE" "\[\]" "\[ \'$ADMIN_MAIL\' \]"
		check_empty_sed "EMAIL_ERROR" "$PAG_CFG_FILE" "root@localhost" "$EMAIL_SYS_ERR"
		check_empty_sed "SMTP_SERVER" "$PAG_CFG_FILE" "localhost" "$SMTP_SRV"
		check_empty_sed "SMTP_PORT" "$PAG_CFG_FILE" "25" "$SMTP_PORT"
		check_empty_sed "SMTP_SSL" "$PAG_CFG_FILE" "False" "$SMTP_SSL"
		check_empty_sed "SMTP_USERNAME" "$PAG_CFG_FILE" "None" "\'$SMTP_USR\'"
		check_empty_sed "SMTP_PASSWORD" "$PAG_CFG_FILE" "None" "\'$SMTP_PSWD\'"
		check_empty_sed "FROM_EMAIL" "$PAG_CFG_FILE" "pagure@localhost.localdomain" "$NOTFY_EMAIL"
		check_empty_sed "DOMAIN_EMAIL_NOTIFICATIONS" "$PAG_CFG_FILE" "localhost.localdomain" "$NOTFY_DOMAIN"
else
echo "There is only a yes | no response."
fi
done

echo -e "\nDo you want to configure your domain?* (yes|no):"
echo "*(Required for SSL setup)"
while [[ $setdomain != yes && $setdomain != no ]]
do
	read setdomain
if [ $setdomain = no ]; then
	echo "If you change your mind, please configure it manually."
elif [ $setdomain = yes ]; then
	echo "Seting domain URL"
		#DOMAIN SETUP
		APP_URL=""
		DOC_APP_URL=""
		# Store data to $SETUP_DOMAIN variable
		SETUP_DOMAIN=$(\
		dialog  --ok-label	"Submit" \
                --backtitle	"Pagure Domain Setup" \
                --title		"Pagure - Domain Options" \
                --form		"Set system values for domain" \
          10 90 0 \
                "Pagure's domain:"		1 1	"$APP_URL" 	1 40 40 0 \
                "Pagure's docs domain:" 2 1	"$DOC_APP_URL"  	2 40 40 0 \
		  3>&1 1>&2 2>&3 3>&- \
		)
		# Extract variables
		APP_URL=$(echo "$SETUP_DOMAIN" | sed -n 1p)
		DOC_APP_URL=$(echo "$SETUP_DOMAIN" | sed -n 2p)
		# Set them in place
		check_empty_sed "APP_URL" "$PAG_CFG_FILE" "localhost.localdomain" "$APP_URL"
		check_empty_sed "DOC_APP_URL" "$PAG_CFG_FILE" "docs.localhost.localdomain" "$DOC_APP_URL"
		check_empty_sed "GIT_URL_SSH" "$PAG_CFG_FILE" "localhost.localdomain" "$APP_URL"
		check_empty_sed "GIT_URL_GIT" "$PAG_CFG_FILE" "localhost.localdomain" "$APP_URL"
else
	echo "There is only a yes | no response."
fi
done

#REDIS
#Using mured.sh - https://github.com/switnet-ltd/mured
echo "Redis sufix:"
read RED_SUFIX
export RED_SUFIX
export RED_CON=1
bash <(curl -s https://raw.githubusercontent.com/switnet-ltd/mured/master/mured.sh)
#Find port from sufix
REDIS_PORT=$(grep -n "port" $(find /etc/redis/redis*.conf) | grep -v "[0-9]:#" | grep _$sufix | awk 'NF>1{print $NF}')
sed -i "s|.*REDIS_PORT.*|REDIS_PORT = $REDIS_PORT|" $PAG_CFG_FILE
RED_DBL=$(grep -n REDIS_DB $PAG_CFG_FILE | cut -d ":" -f1)
RED_DBN=$(grep -n REDIS_DB $PAG_CFG_FILE |rev|awk '{printf $1}')
BRK_INS=$((RED_DBL + 1))
BRK_DBN=$((RED_DBN + 1))
sed -i "${BRK_INS}i BROKER_URL = \'redis://localhost:$REDIS_PORT/$BRK_DBN\'" $PAG_CFG_FILE
usermod -aG redis $PAG_USER

#GITOLITE
##pagure.cfg
#Set fixed python path
sed -i "s|git@|${PAG_USER}@|" $PAG_CFG_FILE
sed -i "s|git://|${PAG_USER}://|" $PAG_CFG_FILE
sed -i "/os.path.abspath/{N;N;N;/)/d;p}" $PAG_CFG_FILE
sed -i "s|GIT_FOLDER =.*|GIT_FOLDER = \'$PAG_HOME/repositories'|" $PAG_CFG_FILE
GIT_FOLDER_INS=$(($( first_nline_patter GIT_FOLDER $PAG_CFG_FILE ) + 1))
sed -i "${GIT_FOLDER_INS}i #DOCS_FOLDER = \'$PAG_HOME/repositories/docs\
#TICKETS_FOLDER = \'$PAG_HOME/repositories/tickets\
#REQUESTS_FOLDER = \'$PAG_HOME/repositories/requests" $PAG_CFG_FILE
sed -i "s|REMOTE_GIT_FOLDER =.*|REMOTE_GIT_FOLDER = \'$PAG_HOME/remotes'|" $PAG_CFG_FILE
sed -i "s|GITOLITE_CONFIG.*|GITOLITE_CONFIG = \'$PAG_HOME/.gitolite/conf/gitolite.conf'|" $PAG_CFG_FILE
sed -i "s|GITOLITE_KEYDIR.*|GITOLITE_KEYDIR = \'$PAG_HOME/.gitolite/keydir'|" $PAG_CFG_FILE
sed -i "s|GITOLITE_HOME.*|GITOLITE_HOME = \'$PAG_HOME'|" $PAG_CFG_FILE
GIT_AUTH_INS=$(($( first_nline_patter GITOLITE_CONFIG $PAG_CFG_FILE ) + 1))
sed -i "${GIT_AUTH_INS}i GIT_AUTH_BACKEND = 'gitolite3'" $PAG_CFG_FILE
sed -i "s|GITOLITE_VERSION|#GITOLITE_VERSION|" $PAG_CFG_FILE
sed -i "s|os.path.join(|None|" $PAG_CFG_FILE
#GL_BINDIR - GITOLITEv2 only
sed -i "s|GL_BINDIR.*|#GL_BINDIR = None|" $PAG_CFG_FILE
##gitolite.rc
#GL_RC - GITOLITEv2 only
sed -i "s|GL_RC.*|#GL_RC = None|" $PAG_CFG_FILE
sed -i "s|/path/to/git/repositories|$PAG_HOME/repositories|" $PAG_HOME/.gitolite.rc
#Set server ssh key.
sudo su $PAG_USER -c "ssh-keygen -t rsa -b 4096"
sudo su $PAG_USER -c "touch $PAG_HOME/.ssh/authorized_keys"

#Create the inital database scheme
sed -i "s|.*script_location.*|script_location = $PAG_HOME_EXT/alembic|" $PAG_CFG_DIR/alembic.ini
sudo su $PAG_USER -c "$PY_VENV_DIR/bin/python3 $PAG_HOME_EXT/createdb.py -i $PAG_CFG_DIR/alembic.ini -c $PAG_CFG_FILE"

## Setup WSGI
sed -i "s|/etc/pagure/pagure.cfg|$PAG_CFG_FILE|" $PAG_USR_SHARE/pagure.wsgi
sed -i "s|/path/to/pagure/|$PAG_HOME_EXT/|" $PAG_USR_SHARE/pagure.wsgi
sed -i "s|#import|import|" $PAG_USR_SHARE/pagure.wsgi
sed -i "s|#sys.|sys.|" $PAG_USR_SHARE/pagure.wsgi
sed -i "s|/etc/pagure/pagure.cfg|$PAG_CFG_FILE|" $PAG_USR_SHARE/doc_pagure.wsgi
sed -i "s|/path/to/pagure/|$PAG_HOME_EXT/|" $PAG_USR_SHARE/doc_pagure.wsgi
sed -i "s|#import|import|" $PAG_USR_SHARE/doc_pagure.wsgi
sed -i "s|#sys.|sys.|" $PAG_USR_SHARE/doc_pagure.wsgi
##Setup Apache & SSL (if requierements on place)
if [ ! -z "$APP_URL" ] && [ ! -z "$DOC_APP_URL" ]; then
echo -e "\nDo you want to setup apache config? (yes|no)"
	while [[ $a2domain != yes && $a2domain != no ]]
	do
	read a2domain
		if [ $a2domain = no ]; then
			echo "If you change your mind, please configure it manually."
		elif [ $a2domain = yes ]; then
			echo "Let's get to it ..."
			install_ifnot apache2
			install_ifnot libapache2-mod-wsgi-py3
			a2enmod ssl headers wsgi cgi
			update_certbot
			cp $PAG_HOME_EXT/files/pagure.conf /etc/apache2/sites-available/$APP_URL.conf
			AP2CONF="/etc/apache2/sites-available/$APP_URL.conf"
			sed -i "s|run/wsgi|/var/run/wsgi|" $AP2CONF
			sed -i "s|=git|=$PAG_USER|g" $AP2CONF
			sed -i "/WSGIDaemonProcess/ s|display-name=pagure|display-name=$PAG_ID|" $AP2CONF
			sed -i "/WSGIDaemonProcess/ s|$| python-home=$PY_VENV_DIR|" $AP2CONF
			sed -i "s|localhost.localdomain|$APP_URL|" $AP2CONF
			sed -i "s|docs.localhost.localdomain|$DOC_APP_URL|" $AP2CONF
			sed -i "s|/usr/share/pagure/pagure.wsgi|$PAG_USR_SHARE/pagure.wsgi|" $AP2CONF
			sed -i "s|/usr/share/pagure/doc_pagure.wsgi|$PAG_USR_SHARE/doc_pagure.wsgi|" $AP2CONF
			sed -i "s|/usr/lib/pythonX.Y/site-packages/pagure/static/|$PAG_HOME_EXT/pagure/static/|" $AP2CONF
			sed -i "s|/var/www/releases|$PAG_HOME/releases|" $AP2CONF
			sed -i "s|/path/to/git/repositories|$PAG_HOME/repositories|" $AP2CONF
			sed -i "s|#||" $AP2CONF
			sed -i "s|SSLCertificate|#SSLCertificate|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|/usr/libexec/git-core/git-http-backend/|/usr/lib/git-core/git-http-backend/|" $AP2CONF
			# Get ssl cert for domain using letsencrypt
			service apache2 stop
			letsencrypt certonly --standalone --renew-by-default --agree-tos --email $ADMIN_MAIL -d $APP_URL
			letsencrypt certonly --standalone --renew-by-default --agree-tos --email $ADMIN_MAIL -d $DOC_APP_URL
			set_ssl_apache "$PAG_USR_SHARE/pagure.wsgi" $AP2CONF $APP_URL
			set_ssl_apache "$PAG_USR_SHARE/doc_pagure.wsgi" $AP2CONF $DOC_APP_URL
			a2ensite $APP_URL.conf
			#TuneUp site performance
			sed -i "s|minutes=20|minutes=60|" $PAG_CFG_FILE
			sed -i "s|.*SESSION_COOKIE_SECURE.*|SESSION_COOKIE_SECURE = True|" $PAG_CFG_FILE
			sed -i "s|.*WEBHOOK.*|WEBHOOK = True|" $PAG_CFG_FILE
			sed -i "s|.*EVENTSOURCE_SOURCE = None.*|EVENTSOURCE_SOURCE = \'https://${APP_URL}\'|" $PAG_CFG_FILE
			service apache2 restart
		fi
	done
fi
if [ ! -z "$APP_URL" ] && [ -z "$DOC_APP_URL" ]; then
echo -e "\nDo you want to setup apache config? (yes|no)"
	while [[ $a2domain != yes && $a2domain != no ]]
	do
	read a2domain
		if [ $a2domain = no ]; then
			echo "If you change your mind, please configure it manually."
		elif [ $a2domain = yes ]; then
			echo "Let's get to it ..."
			install_ifnot apache2
			install_ifnot libapache2-mod-wsgi-py3
			a2enmod ssl headers wsgi cgi
			update_certbot
			cp $PAG_HOME_EXT/files/pagure.conf /etc/apache2/sites-available/$APP_URL.conf
			AP2CONF="/etc/apache2/sites-available/$APP_URL.conf"
			sed -i "s|run/wsgi|/var/run/wsgi|" $AP2CONF
			sed -i "s|=git|=$PAG_USER|g" $AP2CONF
			sed -i "/WSGIDaemonProcess/ s|display-name=pagure|display-name=$PAG_ID|" $AP2CONF
			sed -i "/WSGIDaemonProcess/ s|$| python-home=$PY_VENV_DIR|" $AP2CONF
			sed -i "s|localhost.localdomain|$APP_URL|" $AP2CONF
			sed -i "s|/usr/share/pagure/pagure.wsgi|$PAG_USR_SHARE/pagure.wsgi|" $AP2CONF
			sed -i "s|/usr/lib/pythonX.Y/site-packages/pagure/static/|$PAG_HOME_EXT/pagure/static/|" $AP2CONF
			sed -i "s|/var/www/releases|$PAG_HOME/releases|" $AP2CONF
			sed -i "s|/path/to/git/repositories|$PAG_HOME/repositories|" $AP2CONF
			sed -i "s|#||" $AP2CONF
			sed -i "s|SSLCertificate|#SSLCertificate|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|/usr/libexec/git-core/git-http-backend/|/usr/lib/git-core/git-http-backend/|" $AP2CONF
			sed -i '/<VirtualHost/{:a;N;/\/VirtualHost>/!ba};'"/docs.${APP_URL}/"'d' $AP2CONF
			  sed -i "s|.*WSGIDaemonProcess paguredocs|#WSGIDaemonProcess paguredocs|" $AP2CONF
			  #sed -i "s|.*WSGIDaemonProcess paguredocs:*||" $AP2CONF #comment or delete?
			# Get ssl cert for domain using letsencrypt
			service apache2 stop
			letsencrypt certonly --standalone --renew-by-default --agree-tos --email $ADMIN_MAIL -d $APP_URL
			set_ssl_apache "$PAG_USR_SHARE/pagure.wsgi" $AP2CONF $APP_URL
			a2ensite $APP_URL.conf
			#TuneUp site performance
			sed -i "s|.*SESSION_COOKIE_SECURE.*|SESSION_COOKIE_SECURE = True|" $PAG_CFG_FILE
			sed -i "s|.*WEBHOOK.*|WEBHOOK = True|" $PAG_CFG_FILE
			sed -i "s|.*EVENTSOURCE_SOURCE = None.*|EVENTSOURCE_SOURCE = \'https://${APP_URL}\'|" $PAG_CFG_FILE
			service apache2 restart
		fi
	done
fi

cat  << CELERY >> $PAG_WRK_SRV
[Unit]
Description=Pagure Server
Requires=postgresql.service
After=postgresql.service redis.service
Documentation=https://pagure.io/pagure

[Service]
Type=simple
PermissionsStartOnly=true
User=$PAG_USER
Group=$PAG_USER
WorkingDirectory=$PAG_HOME_EXT
SyslogIdentifier=$PAG_ID
PIDFile=/run/$PAG_USER/$PAG_ID.pid
ExecStartPre=/usr/bin/install -d -m755 -o $PAG_USER -g $PAG_USER /run/$PAG_ID
ExecStart=$PY_VENV_DIR/bin/celery worker -A pagure.lib.tasks_services --loglevel=info
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PY_VENV_DIR/bin"
Environment="PYTHONPATH=$PY_VENV_DIR/lib/python${PYT_V}/site-packages"
Environment="PAGURE_CONFIG=$PAG_CFG_FILE"
ExecStop=/bin/kill -s TERM \$MAINPID

[Install]
WantedBy=multi-user.target
Alias=${PAG_ID}_worker.service
CELERY
systemctl enable $PAG_WRK_SRV
systemctl start ${PAG_ID}_worker.service

#Set gitolite worker
cp $PAG_HOME_EXT/files/pagure_gitolite_worker.service $PAG_GIT_WRK
SRV_GW=$(grep -n "\[Service\]" $PAG_GIT_WRK  | cut -d ":" -f1)
WKD_LIN=$((SRV_GW + 1))
sed -i "${WKD_LIN}i WorkingDirectory=$PAG_HOME_EXT" $PAG_GIT_WRK
sed -i "s|/usr/bin/celery|$PY_VENV_DIR/bin/celery|" $PAG_GIT_WRK
sed -i "s|=git|=$PAG_USER|" $PAG_GIT_WRK
sed -i "s|=/etc/pagure/pagure.cfg|=$PAG_CFG_FILE|" $PAG_GIT_WRK
sed -i "/Environment/i \
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PY_VENV_DIR/bin\" \\
\
Environment=\"PYTHONPATH=$PY_VENV_DIR/lib/python${PYT_V}/site-packages\"" $PAG_GIT_WRK
systemctl enable $PAG_GIT_WRK
systemctl start ${PAG_ID}_gitolite.service

if [ $jenkins = 'yes' ];then
echo "Setting up Jenkins"
sudo su $PAG_USER -c "$PY_VENV_DIR/bin/pip3 install -r $PAG_HOME_EXT/requirements-ci.txt"
sudo su $PAG_USER -c "$PY_VENV_DIR/bin/pip3 install -r $PAG_HOME_EXT/requirements-ev.txt"
#PAGURE-CI
sed -e "s|#\!/usr/bin/env python|#\!${PY_VENV_DIR}/bin/python3|" -i \
$PAG_HOME_EXT/pagure-ev/pagure_stream_server.py
sed -i "/import os/a import sys\\
\
sys.path.insert(0, \'$PAG_HOME_EXT/\')" $PAG_HOME_EXT/pagure-ev/pagure_stream_server.py
chmod +x $PAG_HOME_EXT/pagure-ev/pagure_stream_server.py
cp $PAG_HOME_EXT/files/pagure_ci.service $PAG_CI_WRK
SRV_GW=$(grep -n "\[Service\]" $PAG_CI_WRK  | cut -d ":" -f1)
WKD_LIN=$((SRV_GW + 1))
sed -i "${WKD_LIN}i WorkingDirectory=$PAG_HOME_EXT" $PAG_CI_WRK
sed -i "s|/usr/bin/celery|$PY_VENV_DIR/bin/celery|" $PAG_CI_WRK
sed -i "s|=git|=$PAG_USER|" $PAG_CI_WRK
sed -i "s|=/etc/pagure/pagure.cfg|=$PAG_CFG_FILE|" $PAG_CI_WRK
sed -i "/Environment/i \
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PY_VENV_DIR/bin\" \\
\
Environment=\"PYTHONPATH=$PY_VENV_DIR/lib/python${PYT_V}/site-packages\"" $PAG_CI_WRK
systemctl enable $PAG_CI_WRK
systemctl start ${PAG_ID}_ci.service
cat  << PAG_CI >> $PAG_CFG_FILE

PAGURE_CI_SERVICES = ['jenkins']
PAG_CI
#PAGURE-EV
cp $PAG_HOME_EXT/pagure-ev/pagure_ev.service $PAG_EV_WRK
SRV_GW=$(grep -n "\[Service\]" $PAG_EV_WRK  | cut -d ":" -f1)
WKD_LIN=$((SRV_GW + 1))
sed -i "${WKD_LIN}i WorkingDirectory=$PAG_HOME_EXT" $PAG_EV_WRK
sed -i "s|ExecStart=.*|ExecStart=$PAG_HOME_EXT/pagure-ev/pagure_stream_server.py|" $PAG_EV_WRK
sed -i "s|=git|=$PAG_USER|" $PAG_EV_WRK
sed -i "s|=/etc/pagure/pagure.cfg|=$PAG_CFG_FILE|" $PAG_EV_WRK
sed -i "/Environment/i \
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PY_VENV_DIR/bin\" \\
\
Environment=\"PYTHONPATH=$PY_VENV_DIR/lib/python${PYT_V}/site-packages\"" $PAG_EV_WRK
systemctl enable $PAG_EV_WRK
systemctl start ${PAG_ID}_ev.service
fi
#Clean unused packages
apt -y autoremove
apt autoclean

echo "
Check your browser at: http://$APP_URL"
