#!/bin/bash
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e 'GRANT PROCESS ON *.* TO '"$MYSQL_USER"'@`%`;'
