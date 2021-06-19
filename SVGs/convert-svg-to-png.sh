#!/bin/bash


for svg in *.svg ; do
	png="../PNGs/${svg%.svg}.png"
	inkscape "${svg}" -w 16 -h 16 --export-filename="${png}"
done
