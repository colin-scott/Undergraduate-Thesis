#!/bin/bash

for F in *rb; do
    ruby -c $F
done
