#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Update the package lists for upgrades and new package installations
apt update

# Upgrade the existing packages
apt upgrade -y

# Install and set up necessary software
apt install -y git wget nload bashtop fail2ban apache2 mariadb-server unzip php php-{cli,bcmath,bz2,curl,intl,gd,mbstring,mysql,zip} certbot python3-certbot-apache
mysql_secure_installation

# Download the second script
cd ~/
git clone https://github.com/cjtrowbridge/static-deployment
cd static-deployment

# Create the folder structure
rm -rf /var/www/html
mkdir /var/www/backups
mkdir /var/www/webs
mkdir /var/www/webs/dynamic
mkdir /var/www/webs/static

# Set up static.sh
cp static.sh ~/static.sh
chmod +x ~/static.sh

# Set up permissions fixer and run it
cp fix_permissions.sh ~/fix_permissions.sh
chmod +x ~/fix_permissions.sh
~/fix_permissions.sh

echo "Installation complete. You can now run ~/static.sh to deploy your static websites."
