#!/bin/bash
# Pagure (multi) installer - *buntu 16.04 based.
# SwITNet Ltd © - 2018, https://switnet.net/
# GPLv3 or later.

#Check if user is root
if ! [ $(id -u) = 0 ]; then
   echo "You need to be root or have sudo privileges!"
   exit 1
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
				virtualenv \
				python3-pip \
				python3-jinja2 \
				python3-gdbm \
				redis-server &>/dev/null

echo "gitolite3 gitolite3/adminkey string " | debconf-set-selections
apt -yqq install gitolite3

install_ifnot() {
if [ "$(dpkg-query -W -f='${Status}' $1 2>/dev/null | grep -c "ok")" == "1" ]; then
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

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
install_ifnot language-pack-en-base
install_ifnot postgresql-9.5
echo -e "\n---- PostgreSQL Settings  ----"
sed -i "s|#listen_addresses = 'localhost'|listen_addresses = '*'|g" /etc/postgresql/9.5/main/postgresql.conf

echo "
Please select the suffix for this pagure instance.
"
#Add what has been used  and such as if empty loop
echo "Pagure sufix:"
#PAG_USED=$(grep postgres /opt/pag*/pagure.cfg | grep -v user | cut -d ":" -f3 | cut -d "_" -f2 | sort -r)
PAG_USED=$(sudo -u postgres psql -c "SELECT r.rolname as username,r1.rolname as "role" \
 FROM pg_catalog.pg_roles r LEFT JOIN pg_catalog.pg_auth_members m \
 ON (m.member = r.oid) \
 LEFT JOIN pg_roles r1 ON (m.roleid=r1.oid) \
 WHERE r.rolcanlogin \
 ORDER BY 1;" | sed -n '/pag/p' | cut -d " " -f2 | cut -d "_" -f2 | sort -r)
while [[ -z $sufix ]]
do
echo "These have been already taken (avoid them):"
if [[ -z "$PAG_USED" ]]; then
	echo " -> Seems there is no other Pagure instance present."
else
	echo $PAG_USED
fi
read sufix
if [[ ! -z $sufix ]]; then
	echo "We'll use sufix \"$sufix\" "
else
	echo "Please enter a small sufix for this instance."
fi
done
#Select port and show used by installation.
PAG_PORTS_TAKEN=$(grep 0.0.0.0 /lib/systemd/system/pag*.service | cut -d "'" -f1 | awk 'NF>1{print $NF}' | cut -d ":" -f2 | sort -r)
echo "Choose the port: 5000-5999, the following ports are already taken:"
echo "Enter port:"
if [[ -z "$PAG_PORTS_TAKEN" ]]; then
	echo " -> Seems there is no other instance present."
else
	echo $PAG_PORTS_TAKEN
fi
read PAG_PORT
PAG_USER="pag_$sufix"
PAG_PDB="${PAG_USER}_db"
SHUF=$(shuf -i 15-19 -n 1)
PDB_PASS=$(tr -dc "a-zA-Z0-9@#*=" < /dev/urandom | fold -w "$SHUF" | head -n 1)
PAG_HOME="/opt/$PAG_USER"
PAG_HOME_EXT="$PAG_HOME/$PAG_USER-server"
PAG_CFG_FILE="$PAG_HOME/pagure.cfg"
INIT_FILE=/lib/systemd/system/$PAG_USER-server.service
LOG_FILE=$PAG_HOME/log/$PAG_USER-server.log
ADDRESS=$(hostname -I | cut -d ' ' -f 1)
#--------------------------------------------------
# Create Postgresql user
#--------------------------------------------------
echo -e "\n---- Creating the Pagure PostgreSQL User  ----"
cd /tmp
sudo -u postgres psql <<DB
CREATE DATABASE ${PAG_PDB};
CREATE USER ${PAG_USER} WITH ENCRYPTED PASSWORD '${PDB_PASS}';
GRANT ALL PRIVILEGES ON DATABASE ${PAG_PDB} TO ${PAG_USER};
DB
service postgresql restart

#--------------------------------------------------
# System Settings
#--------------------------------------------------
echo -e "\n---- Creating $PAG_USER system user ----"
adduser --system --quiet --shell=/bin/bash --home=$PAG_HOME --gecos 'Pagure' --group $PAG_USER
usermod -a -G www-data $PAG_USER
echo -e "\n---- Creating log directory ----"
mkdir $PAG_HOME/log/
chown $PAG_USER:$PAG_USER $PAG_HOME/log/

#Retrieve the sources
cd $PAG_HOME
sudo su $PAG_USER -c "git clone --depth 1 https://pagure.io/pagure.git $PAG_HOME_EXT/"
#Apache copy
mkdir -p /var/www/releases_$sufix
chown -R $PAG_USER:$PAG_USER /var/www/releases_$sufix
echo -e "\n---- Installing python (pip) dependacies for pagure ----"
cd $PAG_HOME_EXT
sudo su $PAG_USER -c "virtualenv -p python3 ./venv"
sudo su $PAG_USER -c "source ./venv/bin/activate"
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/pip3 install --upgrade pip"
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/pip3 install psycopg2 gunicorn pygit2==0.24"
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/pip3 install -r $PAG_HOME_EXT/requirements.txt"
#Create the folder that will receive the projects, forks, docs, requests and tickets' git repo
sudo su $PAG_USER -c "mkdir $PAG_HOME_EXT/{repos,docs,forks,tickets,requests}"
sudo su $PAG_USER -c "mkdir $PAG_HOME/remotes"
sudo su $PAG_USER -c "mkdir -p $PAG_HOME/.gitolite/{conf,keydir,logs}"
#Add empty gitolite
sudo su $PAG_USER -c "touch $PAG_HOME/.gitolite/conf/gitolite.conf"
#Setup config files
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/gitolite3.rc $PAG_HOME/.gitolite.rc"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/pagure.cfg.sample $PAG_CFG_FILE"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/alembic.ini $PAG_HOME/alembic.ini"
#sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/pagure.wsgi $PAG_HOME/pagure.wsgi"
#sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/doc_pagure.wsgi $PAG_HOME/doc_pagure.wsgi"

SKEY=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
SMAIL=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
sed -i "s|.*SECRET_KEY.*|SECRET_KEY=\'$SKEY\'|" $PAG_CFG_FILE
sed -i "s|.*SALT_EMAIL.*|SALT_EMAIL=\'$SMAIL\'|" $PAG_CFG_FILE
# DATA BASE
sed -i "s|DB_URL = 'sqlite|#DB_URL = 'sqlite|" $PAG_CFG_FILE
sed -i "$(grep -n "postgres://" $PAG_CFG_FILE | head -n1 | cut -d ":" -f1) s|#DB_URL|DB_URL|" $PAG_CFG_FILE
sed -i "$(grep -n "postgres://" $PAG_CFG_FILE | head -n1 | cut -d ":" -f1) s|user|$PAG_USER|" $PAG_CFG_FILE
sed -i "$(grep -n "postgres://" $PAG_CFG_FILE | head -n1 | cut -d ":" -f1) s|pass|$PDB_PASS|" $PAG_CFG_FILE
sed -i "$(grep -n "postgres://" $PAG_CFG_FILE | head -n1 | cut -d ":" -f1) s|host|localhost|" $PAG_CFG_FILE
sed -i "$(grep -n "postgres://" $PAG_CFG_FILE | head -n1 | cut -d ":" -f1) s|db_name|$PAG_PDB|" $PAG_CFG_FILE

#Enable and setup email
echo -e "\nDo you want to enable and configure email sending? (yes|no):"
while [[ $EMAIL_SET_ANS != yes && $EMAIL_SET_ANS != no ]]
do
	read EMAIL_SET_ANS
if [ $EMAIL_SET_ANS = no ]; then
	echo "Please if you change your mind, you'll need to configure manually!"
elif [ $EMAIL_SET_ANS = yes ]; then
	sed -i "s|.*EMAIL_SEND.*|EMAIL_SEND = True|" $PAG_CFG_FILE
	echo "Starting email setup"
		#EMAIL SETUP
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
		60 90 0 \
				"Email to receive traceback errors:"	1 1	"$EMAIL_SYS_ERR" 	1 40 40 0 \
				"Email used to send notifications:"		2 1	"$NOTFY_EMAIL" 		2 40 40 0 \
				"Domain for notification headers:"		3 1	"$NOTFY_DOMAIN" 	3 40 40 0 \
				"SMTP Server:"  						4 1	"$SMTP_SRV"  		4 40 40 0 \
				"SMTP SSL Port (465):"	   				5 1	"$SMTP_PORT"  		5 40 40 0 \
				"SMTP SSL (True|False):"				6 1	"$SMTP_SSL" 		6 40 40 0 \
				"SMTP Username:"						7 1	"$SMTP_USR" 		7 40 40 0 \
				"SMTP Password:"						8 1	"$SMTP_PSWD" 		8 40 40 0 \
		  3>&1 1>&2 2>&3 3>&- \
		)
		# Extract variables
		EMAIL_SYS_ERR=$(echo "$SETUP_EMAIL" | sed -n 1p)
		NOTFY_EMAIL=$(echo "$SETUP_EMAIL" | sed -n 2p)
		NOTFY_DOMAIN=$(echo "$SETUP_EMAIL" | sed -n 3p)
		SMTP_SRV=$(echo "$SETUP_EMAIL" | sed -n 4p)
		SMTP_PORT=$(echo "$SETUP_EMAIL" | sed -n 5p)
		SMTP_SSL=$(echo "$SETUP_EMAIL" | sed -n 6p)
		SMTP_USR=$(echo "$SETUP_EMAIL" | sed -n 7p)
		SMTP_PSWD=$(echo "$SETUP_EMAIL" | sed -n 8p)

		# Set them in place
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

echo -e "\nDo you want to enable your domain? (yes|no):"
while [[ $setdomain != yes && $setdomain != no ]]
do
	read setdomain
if [ $setdomain = no ]; then
	echo "Please if you change your mind, you'll need to configure manually!"
elif [ $setdomain = yes ]; then
	echo "Seting domain URL"
		#DOMAIN SETUP
		APP_URL=""
		DOC_APP_URL=""
		# Store data to $SETUP_DOMAIN variable
		SETUP_DOMAIN=$(\
		dialog --ok-label "Submit" \
				--backtitle "Pagure Domain Setup" \
				--title "Pagure - Domain Options" \
				--form "Set system values for domain" \
		40 90 0 \
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
export RED_SUFIX=$sufix
export RED_CON=1
bash <(curl -s https://raw.githubusercontent.com/switnet-ltd/mured/master/mured.sh)
#Find port from sufix
REDIS_PORT=$(grep -n "port" $(find /etc/redis/redis*.conf) | grep -v "[0-9]:#" | grep _$sufix | awk 'NF>1{print $NF}')
sed -i "s|.*REDIS_PORT.*|REDIS_PORT = $REDIS_PORT|" $PAG_CFG_FILE
usermod -aG redis $PAG_USER

#Set conf env
export PAGURE_CONFIG=$PAG_CFG_FILE
#Create the inital database scheme
sed -i "s|.*script_location.*|script_location = $PAG_HOME_EXT/alembic|" $PAG_HOME/alembic.ini
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/python $PAG_HOME_EXT/createdb.py -i $PAG_HOME/alembic.ini -c $PAG_CFG_FILE"

## Setup WSGI
#sed -i "s|/etc/pagure/pagure.cfg|$PAG_CFG_FILE|" $PAG_HOME/pagure.wsgi
#sed -i "s|/path/to/pagure/|$PAG_HOME_EXT/|" $PAG_HOME/pagure.wsgi
#sed -i "s|#import|import|" $PAG_HOME/pagure.wsgi
#sed -i "s|#sys.|sys.|" $PAG_HOME/pagure.wsgi
#sed -i "s|/etc/pagure/pagure.cfg|$PAG_CFG_FILE|" $PAG_HOME/doc_pagure.wsgi
#sed -i "s|/path/to/pagure/|$PAG_HOME_EXT/|" $PAG_HOME/doc_pagure.wsgi
#sed -i "s|#import|import|" $PAG_HOME/doc_pagure.wsgi
#sed -i "s|#sys.|sys.|" $PAG_HOME/doc_pagure.wsgi

if [ ! -z "$APP_URL" ] && [ ! -z "$DOC_APP_URL" ]; then
echo -e "\nDo you want to setup apache config (not enabled by default)? (yes|no)"
	while [[ $a2domain != yes && $a2domain != no ]]
	do
	read a2domain
		if [ $a2domain = no ]; then
			echo "Ok, if you change your mind, you'll need to configure manually"
		elif [ $a2domain = yes ]; then
			echo "Let's get to it ..."
			install_ifnot apache2
			cp $PAG_HOME_EXT/files/pagure.conf /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|=git|=$PAG_USER|g" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|localhost.localdomain|$APP_URL|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|docs.localhost.localdomain|$DOC_APP_URL|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|/usr/share/pagure/pagure.wsgi|$PAG_HOME/pagure.wsgi|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|/usr/share/pagure/doc_pagure.wsgi|$PAG_HOME/doc_pagure.wsgi|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|/usr/lib/pythonX.Y/site-packages/pagure/static/|$PAG_HOME_EXT/pagure/static/|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|/var/www/releases|/var/www/releases_$sufix|" /etc/apache2/sites-available/$APP_URL.conf
			sed -i "s|#||" /etc/apache2/sites-available/$APP_URL.conf
			# SSL keys needed, force manual setup.
			sed -i "s|SSLCertificate|#SSLCertificate|" /etc/apache2/sites-available/$APP_URL.conf
			#a2ensite $APP_URL.conf
		fi
	done
fi

cat  << SERVICE >> $INIT_FILE
[Unit]
Description=$PAG_USER Server
Requires=postgresql.service
After=postgresql.service redis.service
[Service]
Type=simple
PermissionsStartOnly=true
User=$PAG_USER
Group=$PAG_USER
WorkingDirectory=$PAG_HOME_EXT
SyslogIdentifier=$PAG_USER
PIDFile=/run/$PAG_USER/$PAG_USER.pid
ExecStartPre=/usr/bin/install -d -m755 -o $PAG_USER -g $PAG_USER /run/$PAG_USER
ExecStart=$PAG_HOME_EXT/venv/bin/gunicorn --bind 0.0.0.0:$PAG_PORT 'pagure.flask_app:create_app()' --env PAGURE_CONFIG=$PAGURE_CONFIG --pid=/run/$PAG_USER/$PAG_USER.pid --access-logfile $LOG_FILE --error-logfile $LOG_FILE --log-level info
ExecStop=/bin/kill -s TERM \$MAINPID
[Install]
WantedBy=multi-user.target
Alias=${PAG_USER}_server.service
SERVICE
systemctl enable $INIT_FILE
systemctl start ${PAG_USER}_server.service

echo "Check your browser at: http://$ADDRESS:$PAG_PORT"
