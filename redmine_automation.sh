#!/usr/bin/env bash

###############################################################################
#                                                                             #
# Redmine stable automatic installation script                                #
#                                                                             #
# Designed for stressed VUAs with little to no wish to copypaste a gadzillion #
# UNIX commands.                                                              #
#                                                                             #
# Copyright (c) 2020 - Bryan Pedini                                           #
#                                                                             #
###############################################################################

_parse_params() {
    VERBOSE=true
    MIGRATE=false
    NO_CONFIGURE_MARIADB=false
    NO_CREATE_USER=false
    REDMINE_VERSION="4.1.0"
    REDMINE_INSTALL_DIR="/opt/redmine"
    for par in "$@"; do
        case "$par" in
            "-h" | "--help" | "--usage")
                _print_usage
                ;;
            "-q" | "--quiet")
                VERBOSE=false
                shift
                ;;
            "--redmine-version")
                [[ "$2:0:1" = "-" ]] && _print_usage
                REDMINE_VERSION="$2"
                shift
                shift
                ;;
            "--install-dir")
                [[ "$2:0:1" = "-" ]] && _print_usage
                REDMINE_INSTALL_DIR="$2"
                shift
                shift
                ;;
            "--no-configure-mariadb")
                NO_CONFIGURE_MARIADB=true
                shift
                ;;
            "--no-create-user")
                NO_CREATE_USER=true
                shift
                ;;
            "--migrate")
                MIGRATE=true
                shift
                ;;
            "--migration-source-sql")
                [[ "$2:0:1" = "-" ]] && _print_usage
                MIGRATION_SQL="$2"
                shift
                shift
                ;;
            "--migration-source-dir")
                [[ "$2:0:1" = "-" ]] && _print_usage
                MIGRATION_DIR="$2"
                shift
                shift
                ;;
        esac
    done
    if [[ ( "$MIGRATE" = true ) && ( "$MIGRATION_SQL" = "" ) ]]; then
        _print_usage "flag --migration passed but either \
--migration-source-sql or
  --migration-source-dir not provided." 1
    fi
}

_print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "OPTIONS"
    echo "  -h, --help, --usage     Prints this help message and exits"
    echo "  -q, --quiet             Turns off verbose logging (default: True)"
    echo "  --redmine-version       Install a custom version of the Redmine
                            project (default: latest)"
    echo "  --install-dir           Specifies a custom path for installation
                            (default: /opt/redmine)"
    echo "  --no-configure-mariadb  Does not launch the default MariaDB server
                            configuration scriptlet (default: False)"
    echo "  --no-create-user        Does not create a \`redmine\` user
                            (default: False)"
    echo "  --migrate               Launches a different procedure for
                            installation, which also import previous
                            existing data (default: False)"
    echo "  --migration-source-sql  Specifies the path of the SQL database
                            export (default: \$PWD/redmine.sql)"
    echo "  --migration-source-dir  Specifies the path of the previous redmine
                            installation. It can either be a different
                            path, or the same as the current installation
                            (default: /opt/redmine)"
    echo
    echo "Encountered error:"
    if [ "$1" ]; then
        echo "  $1"
        if [ "$2" ]; then
            exit $2
        fi
    fi
    exit 0
}

# Update current system
_update_system() {
    [[ "$VERBOSE" = true ]] && echo "Updating current system"
    ERR=$( { apt update 1>/dev/null; } 2>&1 | grep -v "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during package cache update: $ERR"
    ERR=$( { apt -y upgrade 1>/dev/null; } 2>&1 | grep -v \
    "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during system package updates: $ERR"
}

# Install required packages to run Redmine and Ruby on Rails underneath
_install_rails_environment() {
    [[ "$VERBOSE" = true ]] && echo "Installing required packages to run \
Redmine and Ruby on Rails underneath"
    ERR=$( { apt -y install build-essential ruby-dev libxslt1-dev \
        libmariadb-dev libxml2-dev zlib1g-dev imagemagick \
        libmagickwand-dev curl apache2 libapache2-mod-passenger \
        mariadb-client mariadb-server 1>/dev/null; } 2>&1 | grep -v \
        "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during package installations: $ERR"
}

# Add an unprivileged user to run the Redmine app afterwards
_add_redmine_user() {
    [[ "$VERBOSE" = true ]] && echo "Adding an unprivileged user to run the \
Redmine app afterwards"
    useradd -r -m -d "$REDMINE_INSTALL_DIR" -s /usr/bin/bash redmine &>/dev/null && \
    usermod -aG redmine www-data &>/dev/null
}

# Ask the user for mysql `root` password and configure mysql in unattended mode
_configure_mariadb_server() {
    read -sp 'Please type a `root` password for mysql database: ' \
            MYSQL_ROOT_PASSWORD && echo ""

    [[ "$VERBOSE" = true ]] && echo "Configuring mysql in unattended mode"
    ERR=$( { apt -y install expect >/dev/null; } 2>&1 | grep -v \
    "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during package installations: $ERR"
    SECURE_MYSQL=$(expect -c "
        set timeout 10
        spawn mysql_secure_installation
        expect \"Enter current password for root (enter for none):\"
        send \"\r\"
        expect \"Set root password?\"
        send \"y\r\"
        expect \"New password:\"
        send \"$MYSQL_ROOT_PASSWORD\r\"
        expect \"Re-enter new password:\"
        send \"$MYSQL_ROOT_PASSWORD\r\"
        expect \"Remove anonymous users?\"
        send \"y\r\"
        expect \"Disallow root login remotely?\"
        send \"y\r\"
        expect \"Remove test database and access to it?\"
        send \"y\r\"
        expect \"Reload privilege tables now?\"
        send \"y\r\"
        expect eof
    ")
    ERR=$( { echo "$SECURE_MYSQL" 1>/dev/null; } 2>&1 )
    [[ "$ERR" ]] && echo "Error during mysql_initialization: $ERR"
    ERR=$( { apt -y remove --purge expect >/dev/null; } 2>&1 | \
        grep -v "stable CLI interface" )
    [[ "$ERR" ]] && echo "Error during package removals: $ERR"

    unset SECURE_MYSQL
}

# Create Redmine database with associated login
_configure_redmine_database() {
    [[ "$VERBOSE" = true ]] && echo "Creating Redmine database with \
associated login"
    MYSQL_ROOT_USER="root"
    QUERY="command=password&format=plain&scheme=rrnnnrrnrnnnrrnrnnrr"
    REDMINE_ADMIN_PASSWORD=$(curl -s \
    "https://www.passwordrandom.com/query?$QUERY")
    SQL="CREATE DATABASE redmine;"
    mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASSWORD -e "$SQL"
    SQL="GRANT ALL PRIVILEGES ON redmine.* TO redmine_admin@localhost
    IDENTIFIED BY '$REDMINE_ADMIN_PASSWORD';"
    mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASSWORD -e "$SQL"
    SQL="FLUSH PRIVILEGES;"
    mysql -u$MYSQL_ROOT_USER -p$MYSQL_ROOT_PASSWORD -e "$SQL"

    unset SQL; unset MYSQL_ROOT_USER; unset MYSQL_ROOT_PASSWORD; unset QUERY
}

# Download Redmine on temporary directory, extract it on /opt and reconfigure
# default config parameters with real values
_download_redmine() {
    [[ "$VERBOSE" = true ]] && echo "Downloading Redmine on temporary \
directory"
    ERR=$( { wget -q \
        http://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz -P \
        /tmp/ && wget -q \
        http://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz.md5 \
        -P /tmp/ && cd /tmp/ && md5sum -c \
        redmine-${REDMINE_VERSION}.tar.gz.md5 1>/dev/null; } 2>&1 )
    [[ "$ERR" ]] && echo "Error downloading or verifying signature of \
Redmine: $ERR"
    rm /tmp/redmine-${REDMINE_VERSION}.tar.gz.md5

    [[ "$VERBOSE" = true ]] && echo "Extracting Redmine on \
$REDMINE_INSTALL_DIR"
    mkdir "$REDMINE_INSTALL_DIR" && chown redmine:redmine \
    "$REDMINE_INSTALL_DIR"
    sudo -u redmine tar xzf /tmp/redmine-${REDMINE_VERSION}.tar.gz -C \
    "$REDMINE_INSTALL_DIR" --strip-components=1

    [[ "$VERBOSE" = true ]] && echo "Configuring Redmine"
    sudo -u redmine cp \
    "$REDMINE_INSTALL_DIR"/config/configuration.yml{.example,} && sudo \
    -u redmine cp "$REDMINE_INSTALL_DIR"/config/database.yml{.example,} \
    && sudo -u redmine cp \
    "$REDMINE_INSTALL_DIR"/public/dispatch.fcgi{.example,}
    sed -i "0,/root/s//redmine_admin/" \
    "$REDMINE_INSTALL_DIR"/config/database.yml
    sed -i "0,/\"\"/s//\"$REDMINE_ADMIN_PASSWORD\"/" \
    "$REDMINE_INSTALL_DIR"/config/database.yml
    unset REDMINE_ADMIN_PASSWORD
    unset REDMINE_VERSION
}

_configure_redmine_permissions() {
    # Create required Redmine folders and set correct permissions
    [[ "$VERBOSE" = true ]] && echo "Creating required Redmine folders and \
set correct permissions"
    sudo -u redmine mkdir -p tmp/pdf
    sudo -u redmine mkdir -p public/plugin_assets
}

_configure_redmine_dependencies() {
    # Install required Ruby files
    [[ "$VERBOSE" = true ]] && echo "Installing required Ruby files"
    cd "$REDMINE_INSTALL_DIR"
    ERR=$( { gem install bundler 1>/dev/null; } 2>&1 )
    [[ "$ERR" ]] && echo "Error while installing bundler Gem: $ERR"
    sudo -u redmine bundle config set path "vendor/bundle"
    sudo -u redmine bundle config set without "development test"
    ERR=$( { sudo -u redmine bundle install 1>/dev/null; } 2>&1 )
    [[ "$ERR" ]] && echo "Error while installing Redmine bundled Gems: $ERR"
    sudo -u redmine bundle exec rake generate_secret_token 1>/dev/null
    sudo -u redmine RAILS_ENV=production bundle exec rake db:migrate \
    1>/dev/null

    # Only if not migrating, load default redmine data
    [[ ! "$MIGRATE" ]] && sudo -u redmine RAILS_ENV=production \
    REDMINE_LANG=en bundle exec rake redmine:load_default_data 1>/dev/null
}

# Configure Apache2 to run Redmine
_configure_apache2() {
    # Ask the user for Apache2 Redmine hostname
    read -p 'Please type the FQDN Redmine should run on: ' \
    REDMINE_HOSTNAME && echo ""

    [[ "$VERBOSE" = true ]] && echo "Configuring Apache2 to run Redmine"
    cat << "EOF" > /etc/apache2/sites-available/redmine.conf
<VirtualHost *:80>
    ServerName $REDMINE_HOSTNAME
    RailsEnv production
    DocumentRoot "$REDMINE_INSTALL_DIR/public"

    <Directory "$REDMINE_INSTALL_DIR/public">
            Allow from all
            Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/redmine_error.log
    CustomLog \${APACHE_LOG_DIR}/redmine_access.log combined
</VirtualHost>
EOF
    unset REDMINE_HOSTNAME; unset REDMINE_INSTALL_DIR
}

# Enable passenger module if not already done
_enable_redmine() {
    [[ "$VERBOSE" = true ]] && echo "Enabling passenger module if not already \
done"
    [[ ! "$( apache2ctl -M | grep -i passenger )" ]] && a2enmod passenger

    # Enable redmine website over Apache2
    [[ "$VERBOSE" = true ]] && echo "Enabling redmine website over Apache2"
    a2ensite redmine 1>/dev/null
    systemctl reload apache2
}

# Main program function, calls all other functions in the correct order
_main() {
    _update_system
    _install_rails_environment
    [[ "$NO_CREATE_USER" = false ]] && _add_redmine_user
    [[ "$NO_CONFIGURE_MARIADB" = false ]] && _configure_mariadb_server
    _configure_redmine_database
    _download_redmine
    _configure_redmine_permissions
    _configure_redmine_dependencies
    _configure_apache2
    _enable_redmine
}

# Program execution
_parse_params $@
_main
