#!/bin/bash
# can disable redis and run this script to test performance without caching
URL="http://localhost:3000/api/v1/pricing?period=Winter&hotel=FloatingPointResort&room=SingletonRoom"

for i in {1..100}
do
   echo "Request $i"
   curl -s "$URL"
   sleep 0.6
done