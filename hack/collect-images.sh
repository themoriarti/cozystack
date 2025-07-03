#!/bin/sh

for node in 11 12 13; do
  talosctl -n 192.168.123.${node} -e 192.168.123.${node} images ls >> images.tmp
  talosctl -n 192.168.123.${node} -e 192.168.123.${node} images --namespace system ls >> images.tmp
done

while read _ name sha _ ; do echo $sha $name ; done < images.tmp | sort -u > images.txt
