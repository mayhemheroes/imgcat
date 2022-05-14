# Build Stage
FROM --platform=linux/amd64 ubuntu:20.04 as builder

## Install build dependencies.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y cmake

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y git

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y libjpeg-dev

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y libncurses5-dev

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y g++

## Add source code to the build stage.
ADD . /imgcat
WORKDIR /imgcat

## TODO: ADD YOUR BUILD INSTRUCTIONS HERE.
RUN git submodule update --init --recursive
RUN ./configure
RUN make

#Package Stage
FROM --platform=linux/amd64 ubuntu:20.04

## TODO: Change <Path in Builder Stage>
COPY --from=builder /imgcat/imgcat /
