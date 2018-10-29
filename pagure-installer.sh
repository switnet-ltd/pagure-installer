#!/bin/bash
# Pagure (multi) installer - *buntu 16.04 based.
# SwITNet Ltd © - 2018, https://switnet.net/
# GPLv3 or later.

#Check if user is root
if ! [ $(id -u) = 0 ]; then
   echo "You need to be root or have sudo privileges!"
   exit 1
fi

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
				python-pip3 \
				python-jinja2 \
				python-gdbm \
				redis-server &>/dev/null

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
apt install -yqq language-pack-en-base

if [ "$(dpkg-query -W -f='${Status}' postgresql-9.5 2>/dev/null | grep -c "ok")" == "1" ]; then
		echo "Postgresql is installed, skipping..."
    else
		echo -e "\n---- Install PostgreSQL Server ----"
		apt -yqq install postgresql-9.5

		echo -e "\n---- PostgreSQL Settings  ----"
		sed -i "s|#listen_addresses = 'localhost'|listen_addresses = '*'|g" /etc/postgresql/9.5/main/postgresql.conf
fi

echo "
Please select the suffix for this pagure instance.
"
#Add what has been used  and such as if empty loop
echo "Pagure sufix:"
PAG_USED=$(grep postgres /opt/pag*/pagure.cfg | grep -v user | cut -d ":" -f3 | cut -d "_" -f2 | sort -r)
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
PAG_USER="pag_$sufix"
PAG_PDB="${PAG_USER}_db"
SHUF=$(shuf -i 15-19 -n 1)
PDB_PASS=$(tr -dc "a-zA-Z0-9@#*=" < /dev/urandom | fold -w "$SHUF" | head -n 1)
PAG_HOME="/opt/$PAG_USER"
PAG_HOME_EXT="$PAG_HOME/$PAG_USER-server"
PAG_CFG_FILE="$PAG_HOME/pagure.cfg"
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
echo -e "\n---- Create Pagure system user ----"
adduser --system --quiet --shell=/bin/bash --home=$PAG_HOME --gecos 'Pagure' --group $PAG_USER
usermod -a -G www-data $PAG_USER
echo -e "\n---- Create Log directory ----"
mkdir $PAG_HOME/log/
chown $PAG_USER:$PAG_USER $PAG_HOME/log/

#Retrieve the sources
cd $PAG_HOME
sudo su $PAG_USER -c "git clone --depth 1 https://github.com/Pagure/pagure $PAG_HOME_EXT/"
#Apache copy
mkdir -p /var/www/releases_$sufix
chown -R $PAG_USER:$PAG_USER /var/www/releases_$sufix
echo -e "\n---- Install tool packages ----"
cd $PAG_HOME_EXT
sudo su $PAG_USER -c "virtualenv -p python3 ./venv"
sudo su $PAG_USER -c "source ./venv/bin/activate"
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/pip3 install --upgrade pip3"
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/pip3 install pygit2==0.24 psycopg2"
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/pip3 install -r $PAG_HOME_EXT/requirements.txt"
#Create the folder that will receive the projects, forks, docs, requests and tickets' git repo
sudo su $PAG_USER -c "mkdir $PAG_HOME_EXT/{repos,docs,forks,tickets,requests}"
sudo su $PAG_USER -c "mkdir $PAG_HOME/remotes"
sudo su $PAG_USER -c "mkdir $PAG_HOME/.gitolite/{conf,keydir,logs}"
#Add empty gitolite
sudo su $PAG_USER -c "touch $PAG_HOME/.gitolite/conf/gitolite.conf"
#Setup config file
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/gitolite3.rc $PAG_HOME/.gitolite.rc"
sudo su $PAG_USER -c "cp $PAG_HOME_EXT/files/pagure.cfg.sample $PAG_CFG_FILE"

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
		"Domain email notification:"			3 1	"$NOTFY_DOMAIN" 	3 40 40 0 \
		"SMTP Server:"  						4 1	"$SMTP_SRV"  		4 40 40 0 \
		"SMTP Port (465):"	   					5 1	"$SMTP_PORT"  		5 40 40 0 \
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

check_empty_sed() {
if [[ -z "$4" ]]; then
	echo "Empty $1 variable, leaving default"
else
	sed -i "$(grep -n $1 $2 | head -n 1 | cut -d ":" -f1) s|$3|$4|" $2
fi
}
check_empty_sed "EMAIL_ERROR" "$PAG_CFG_FILE" "root@localhost" "$EMAIL_SYS_ERR"
check_empty_sed "SMTP_SERVER" "$PAG_CFG_FILE" "localhost" "$SMTP_SRV"
check_empty_sed "SMTP_PORT" "$PAG_CFG_FILE" "25" "$SMTP_PORT"
check_empty_sed "SMTP_SSL" "$PAG_CFG_FILE" "False" "$SMTP_SSL"
check_empty_sed "SMTP_USERNAME" "$PAG_CFG_FILE" "None" "\'$SMTP_USR\'"
check_empty_sed "SMTP_PASSWORD" "$PAG_CFG_FILE" "None" "\'$SMTP_PSWD\'"
check_empty_sed "FROM_EMAIL" "$PAG_CFG_FILE" "pagure@localhost.localdomain" "$NOTFY_EMAIL"
check_empty_sed "DOMAIN_EMAIL_NOTIFICATIONS" "$PAG_CFG_FILE" "localhost.localdomain" "$NOTFY_DOMAIN"

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

#REDIS
#Using mured.sh - https://github.com/switnet-ltd/mured
export RED_SUFIX=$sufix
bash <(curl -s https://raw.githubusercontent.com/switnet-ltd/mured/master/mured.sh)
#Find port from sufix
REDIS_PORT=$(grep -n "port" $(find /etc/redis/redis*.conf) | grep -v "[0-9]:#" | grep _$sufix | awk 'NF>1{print $NF}')
sed -i "s|.*REDIS_PORT.*|REDIS_PORT = $REDIS_PORT|" $PAG_CFG_FILE
usermod -aG redis $PAG_USER

#Set conf env
export PAGURE_CONFIG=$PAG_CFG_FILE
#Create the inital database scheme
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/python $PAG_HOME_EXT/createdb.py -i $PAG_HOME_EXT/files/alembic.ini"
#ToDo: Replaced by a startup script
sudo su $PAG_USER -c "$PAG_HOME_EXT/venv/bin/python $PAG_HOME_EXT/runserver.py --host=0.0.0.0 -p 5000"
