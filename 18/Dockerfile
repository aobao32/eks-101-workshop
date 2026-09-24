FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# Install iperf2 (prebuilt RPM for Amazon Linux 2023 x86_64) and network troubleshooting tools
RUN dnf install -y \
    https://blogimg.bitipcman.com/workshop/EC2-iperf2/iperf-2.1.9-1.amzn2023.x86_64.rpm \
    iproute \
    ethtool \
    procps-ng \
 && dnf clean all

# iperf2 listens on TCP/UDP 5001 by default
EXPOSE 5001/tcp
EXPOSE 5001/udp

# Run iperf2 as server in foreground
CMD ["iperf", "-s"]
