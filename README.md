servicebackup
=============

This software is used to backup MySQL database and regular files by the full, incremental and differential backups,
in a managable method that can be recovered easily by both software and manual.

It can be used to backup web sites, your working folders etc.

Install
-------

Following we will install the software in directory /backup and
store backup data in that directory. We also setup a cron job for
to run the backup job repeatly and another host to sync the backup data remotely.

### Prerequisites

The software depends on following packages:

    percona-xtrabackup
    qpress

To install the packages in Debian/Ubuntu:

    apt-get install percona-xtrabackup
    wget http://www.quicklz.com/qpress-11-linux-x64.tar
    sudo tar -C /usr/bin/ qpress-11-linux-x64.tar

In Arch Linux:

    pacman -S xtrabackup qpress

### Install software

Create directory to store backup data:

    mkdir /backup

Copy all of files in the directory /backup:

    /backup/
    ├── src/
    │   ├── libconfig.sh        # bash lib for read config file
    │   ├── libbash.sh          # bash lib misc functions
    │   ├── libbackup.sh        # bash lib backup routines
    │   ├── backup.sh           # the backup script
    │   └── restore.sh          # the restore script
    └── backup.conf             # global config variables

### Add backup user

Create a backup user, we use 'backupper' here, as a system user.

    useradd -m -g users -s /bin/bash backupper

For MySQL, you need also setup up a backup user in the database.

    mysql -u root -p

    CREATE USER 'backupper'@'localhost' IDENTIFIED BY 'password';
    GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backupper'@'localhost';
    FLUSH PRIVILEGES;

    exit

To make it work, you need also need to set the following item in your MySQL config file /etc/mysql/my.cnf:

    [mysqld]
    datadir = /var/lib/mysql
    innodb_log_files_in_group=2

You need to change the config items according your current MySQL settings.

### Test and run in local host

Setup backup.conf for your services, and test if it work:

    cd /backup/src/; ./backup.sh

It will generate several tar.gz files in /backup/.

### Add it to cron job

Install cron and add one line in file /etc/crontab:

    0 3 * * * root /backup/src/backup.sh /backup/backup.conf

restart your cron

    which systemctl >/dev/null 2>&1 && systemctl restart cron
    which service >/dev/null 2>&1 && service cron restart


### Remote host backup

To store the backup data in remote host, we using following steps.

Create a backup user in remote host:

    useradd -m -g users -s /bin/bash backupper

Setup ssh id:

    su - backupper
    ssh-keygen
    ssh-copy-id -p 22 -i ~/.ssh/id_rsa.pub backupper@yourlocalhost.com

Create a script sync.sh in your home directory :

    #!/bin/sh
    rsync -az -e "ssh -p 22" backupper@yourlocalhost.com:/backup /home/backupper

and add it to /etc/crontab:

    0 15 * * * backupper /home/backupper/sync.sh

restart cron:

    which systemctl >/dev/null 2>&1 && systemctl restart cron
    which service >/dev/null 2>&1 && service cron restart


The backupped data files
------------------------

The name of the files/directories is combined with the prefix, name of backup, timestamp, backup types.
So you can locate the required files easily, and recovery it either by software automately or by manual.



Restore
-------

It's very easy to restore all of data, just use the script restore.sh, for example:

    /backup/src/restore /backup/backup.conf

It will search the files in the directory specified by DN_BAK in config file /backup/backup.conf,
and then use the latest full/differential/incremental files to restore the data.


The backup config file
----------------------

The MySQL related parameters:

    DB_USER="backupper"
    DB_PW="password"
    #DB_HOST="localhost"
    #DB_PORT=3306
    #DB_CONF="/etc/mysql/my.cnf"
    DB_CONF="/etc/my.cnf"

The admin email is used to receive messages when the DB server is not up.

    EMAIL_ADMIN="youraccount@gmail.com"

The backup list is a comma splitted list of the backup config block, the format of each block is

    <name>  <type> <backup callback> <restore callback> <data dir>

  * name: is the name of backup
  * type: is either 'f' or 'd' for file and directory. it depends on the implementation of callback functions
  * backup callback, restore callback: is the bash callback function implemented for various data source
  * data dir: is the directory where the data to be saved.

example:
BAK_LIST="mysql     d backupcb_mysql restorecb_mysql /usr/local/mysql/var/, confetc   f backupcb_files restorecb_files /etc/"

