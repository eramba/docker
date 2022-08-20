#!/bin/bash
mysql -u root -pdocker -e 'GRANT PROCESS ON *.* TO docker@`%`;'
