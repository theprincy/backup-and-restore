for f in *.sql.gz; do
   db="${f%%.*}"
   echo "creating database $db"
   mysql -h localhost -u root -p mysql --password=passwd <<< "create database $db"
   echo "restoring database $db"
   gunzip "$f"
   mysql -h localhost -u root -ppasswd "$db" < "$db.sql"
done
