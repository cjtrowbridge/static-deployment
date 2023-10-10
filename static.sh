#!/bin/bash

# Define paths for dynamic and static directories
DYNAMIC_DIR="/var/www/webs/dynamic"
STATIC_DIR="/var/www/webs/static"

# Function to create a new site
create_new_site() {
    # Ask the user for the FQDN
    read -p "Enter the FQDN for the new site: " fqdn

    # Construct the full path for this FQDN in both directories
    dynamic_fqdn_path="$DYNAMIC_DIR/$fqdn"
    static_fqdn_path="$STATIC_DIR/$fqdn"

    # Check if the FQDN directory already exists in either directory
    if [[ -d "$dynamic_fqdn_path" || -d "$static_fqdn_path" ]]; then
        echo "Error: The site $fqdn already exists!"
        exit 1
    fi

    # If it doesn't exist, create the directory in both locations
    mkdir -p "$dynamic_fqdn_path"
    mkdir -p "$static_fqdn_path"
    
    # Download and unzip WordPress into the dynamic FQDN directory
    echo "Downloading the latest WordPress package..."
    wget -q https://wordpress.org/latest.zip -P "$dynamic_fqdn_path"

    echo "Unzipping WordPress..."
    unzip -q "$dynamic_fqdn_path/latest.zip" -d "$dynamic_fqdn_path"

    # Since WordPress zip extracts to a 'wordpress' directory, we'll move its content up a level
    mv "$dynamic_fqdn_path/wordpress/"* "$dynamic_fqdn_path"
    rmdir "$dynamic_fqdn_path/wordpress/"
    rm "$dynamic_fqdn_path/latest.zip"
    echo "WordPress setup in $dynamic_fqdn_path."

    # Database setup
    # For simplicity's sake, sanitize the fqdn to create DB names and usernames by replacing dots with underscores.
    db_name=$(echo "$fqdn" | tr . _)
    db_user=$db_name
    db_pass=$(openssl rand -base64 32) # This command generates a strong random password

    # Command to MySQL/MariaDB
    SQL_COMMAND="CREATE DATABASE $db_name;
                 CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
                 GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';
                 FLUSH PRIVILEGES;"

    echo "Setting up the database..."
    mysql -u root -e "$SQL_COMMAND"

    # Update WordPress configuration
    wp_config="$dynamic_fqdn_path/wp-config.php"
    if [ -f "$wp_config" ]; then
        # Copy the sample configuration to the real configuration
        cp "$dynamic_fqdn_path/wp-config-sample.php" "$wp_config"
        
        # Replace database name, user, and password in the WordPress configuration file
        sed -i "s/database_name_here/$db_name/g" "$wp_config"
        sed -i "s/username_here/$db_user/g" "$wp_config"
        sed -i "s/password_here/$db_pass/g" "$wp_config"

        # Fetch and update unique keys and salts
        echo "Fetching and updating unique keys and salts..."
        SALT=$(wget -q -O - https://api.wordpress.org/secret-key/1.1/salt/)
        if [ "$?" -eq 0 ]; then
            # Escape slashes for use with sed
            SALT_ESCAPED=$(echo "$SALT" | sed 's:[\/&]:\\&:g')
            # Use a delimiter other than '/' for sed since the salts have '/' in them
            sed -i "/^define('AUTH_KEY'/,/^define('NONCE_SALT'/c\\$SALT_ESCAPED" "$wp_config"
            echo "Unique keys and salts updated in WordPress configuration."
        else
            echo "Error fetching unique keys and salts. Please update them manually."
        fi
        echo "WordPress configuration updated."
    else
        echo "Error: WordPress configuration file not found!"
        exit 1
    fi

    # Set up Apache dynamic configuration
    echo "Setting up Apache dynamic configuration for $fqdn..."
    APACHE_DYNAMIC_CONF_PATH="/etc/apache2/sites-available/$fqdn.dynamic.conf"
    cp ~/static-deployment/example.conf "$APACHE_DYNAMIC_CONF_PATH"
    sed -i "s|fqdn|$fqdn|g" "$APACHE_DYNAMIC_CONF_PATH"
    a2ensite "$fqdn.dynamic"  # Enabling the site configuration without ".conf"
    systemctl reload apache2

    # Set up Apache static configuration
    echo "Setting up Apache static configuration for $fqdn..."
    APACHE_STATIC_CONF_PATH="/etc/apache2/sites-available/$fqdn.static.conf"
    cp "$APACHE_DYNAMIC_CONF_PATH" "$APACHE_STATIC_CONF_PATH"
    sed -i "s|/var/www/webs/dynamic/$fqdn|/var/www/webs/static/$fqdn|g" "$APACHE_STATIC_CONF_PATH"
    echo "Apache static configuration set up for $fqdn."

    # Install SSL using Certbot
    echo "Setting up SSL for $fqdn..."
    certbot --apache --non-interactive --agree-tos --redirect --email cj@cjtrowbridge.com -d $fqdn
    if [ $? -eq 0 ]; then
        echo "SSL successfully set up for $fqdn."
    else
        echo "Error setting up SSL for $fqdn. Please check the Certbot logs and retry."
        exit 1
    fi
}

# Function to manage an existing site
manage_existing_site() {
    local selected_site=$1
    
    # Check if the dynamic configuration is active
    if [[ -L "/etc/apache2/sites-enabled/$selected_site.dynamic.conf" ]]; then
        echo "$selected_site is in DYNAMIC mode."
    elif [[ -L "/etc/apache2/sites-enabled/$selected_site.static.conf" ]]; then
        echo "$selected_site is in STATIC mode."
    else
        echo "No active configuration found for $selected_site."
    fi

    # Present menu for mode selection
    echo "-----------------------------------"
    echo "1) Set to DYNAMIC mode"
    echo "2) Set to STATIC mode"
    echo "-----------------------------------"
    read -p "Enter your choice: " choice

    case $choice in
    1)
        # Enable DYNAMIC mode, disable STATIC mode
        a2ensite "$selected_site.dynamic.conf"
        a2dissite "$selected_site.static.conf"
        echo "Setting $selected_site to DYNAMIC mode."
        ;;
    2)
        # Enable STATIC mode, disable DYNAMIC mode
        a2ensite "$selected_site.static.conf"
        a2dissite "$selected_site.dynamic.conf"
        echo "Setting $selected_site to STATIC mode."
        
        # Ask user if they want to refresh the static copy
        read -p "Do you want to refresh the static copy of the site? (y/n): " refresh_choice
        if [[ "$refresh_choice" == "y" ]]; then
            refresh_static_copy "$selected_site"
        fi
        ;;
    *)
        echo "Invalid choice!"
        exit 1
        ;;
    esac

    # Restart Apache to apply changes
    systemctl restart apache2
    echo "$selected_site mode change applied."
}

# Function to refresh the static copy of a site
refresh_static_copy() {
    local fqdn=$1
    local target_directory="$STATIC_DIR/$fqdn.temp"

    # Create a temp directory in the static folder
    mkdir -p "$target_directory"

    # Recursively download the entire website
    echo "Starting the mirroring process for $fqdn ..."
    wget \
        --recursive \
        --no-clobber \
        --page-requisites \
        --html-extension \
        --convert-links \
        --restrict-file-names=windows \
        --no-parent \
        --directory-prefix "$target_directory" \
        "http://$fqdn"

    if [ $? -eq 0 ]; then
        # If wget completes successfully
        echo "Mirroring completed successfully."

        # Delete the existing static fqdn directory
        rm -rf "$STATIC_DIR/$fqdn"

        # Rename the temp directory
        mv "$target_directory" "$STATIC_DIR/$fqdn"

        echo "Static copy of $fqdn has been refreshed successfully."
    else
        # If wget encounters an error
        echo "Error occurred during mirroring. The static copy has not been updated."
        rm -rf "$target_directory"
    fi
}

# Display menu and take user input
# Get a list of all FQDNs from both directories
ALL_SITES=$(echo $(ls $DYNAMIC_DIR) $(ls $STATIC_DIR) | tr ' ' '\n' | sort -u)

# Display menu
echo "Please select an option:"
echo "-----------------------------------"
echo "1) Create a new site"
index=2
for site in $ALL_SITES; do
    echo "$index) $site"
    ((index++))
done
echo "-----------------------------------"

# Get user's choice
read -p "Enter your choice: " choice

if [ "$choice" -eq 1 ]; then
    create_new_site
else
    selected_site=$(echo "$ALL_SITES" | sed "${choice}q;d" -n)
    if [ -z "$selected_site" ]; then
        echo "Invalid choice!"
        exit 1
    else
        manage_existing_site "$selected_site"
    fi
fi
