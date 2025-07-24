NAME=seaweedfs

include ../../../scripts/package.mk

generate:
	readme-generator-for-helm -v values.yaml -s values.schema.json -r README.md
	yq -o json -i '.properties.topology.enum = ["Simple","MultiZone","Client"]' values.schema.json
