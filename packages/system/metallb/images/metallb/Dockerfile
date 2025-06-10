# syntax=docker/dockerfile:1.2

ARG VERSION

FROM quay.io/metallb/controller:${VERSION} as controller

FROM quay.io/metallb/speaker:${VERSION} as speaker
