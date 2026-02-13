#!/bin/bash

# Define the arrays
periods=("Summer" "Autumn" "Winter" "Spring")
hotels=("FloatingPointResort" "GitawayHotel" "RecursionRetreat")
rooms=("SingletonRoom" "BooleanTwin" "RestfulKing")

for i in {1..100}
do
  # Pick random elements
  p=${periods[$RANDOM % ${#periods[@]}]}
  h=${hotels[$RANDOM % ${#hotels[@]}]}
  r=${rooms[$RANDOM % ${#rooms[@]}]}

  echo "Request $i: $p | $h | $r"

  # Execute the curl
  curl -s "http://localhost:3000/api/v1/pricing?period=$p&hotel=$h&room=$r"
  
  # Sleep for 0.6 seconds to spread 100 calls over 1 minute
  sleep 0.6
done