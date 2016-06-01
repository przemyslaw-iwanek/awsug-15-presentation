# Copyright (C) 2016 Cognifide Limited
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Written by:
#   Przemysław Iwanek <przemyslaw.iwanek@cognifide.com> and contributors
#   March 2016
# 

###### PREPARING THE CONNECTION

# Define required variables
variable "aws_access" {}
variable "aws_secret" {}
variable "przemek_key" {}

# Initialize AWS connection
provider "aws" {
    access_key = "${var.aws_access}"
    secret_key = "${var.aws_secret}"
    region = "eu-west-1"
}

###### CREATING THE NETWORKS


# Create VPC
resource "aws_vpc" "demo-vpc" {
    cidr_block = "10.11.12.0/28"
}

# Create DHCP Options
resource "aws_vpc_dhcp_options" "dhcp-opts" {
    domain_name = "example.domain.local"
    domain_name_servers = [
        "127.0.0.1",
        "AmazonProvidedDNS"
    ]
}

# Associate DHCP options with VPC
resource "aws_vpc_dhcp_options_association" "dhcp-opts-assoc" {
    vpc_id = "${aws_vpc.demo-vpc.id}"
    dhcp_options_id = "${aws_vpc_dhcp_options.dhcp-opts.id}"
}

# Create Internet Gateway
resource "aws_internet_gateway" "igw" {
    vpc_id = "${aws_vpc.demo-vpc.id}"
}

# Create Route Table
resource "aws_route_table" "rt-public" {
    vpc_id = "${aws_vpc.demo-vpc.id}"

    # Associate IGW with this Route Table as default route
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = "${aws_internet_gateway.igw.id}"
    }
}

# Create Subnet in second availability zone
resource "aws_subnet" "subnet-public" {
    vpc_id = "${aws_vpc.demo-vpc.id}"

    cidr_block = "10.11.12.0/28"
    availability_zone = "eu-west-1b"
}

# Associate Subnet with Route Table
resource "aws_route_table_association" "subnet-public-assoc" {
    subnet_id = "${aws_subnet.subnet-public.id}"
    route_table_id = "${aws_route_table.rt-public.id}"
}


###### CREATING THE INSTANCE


# Create security group
resource "aws_security_group" "sg-demo" {
    vpc_id = "${aws_vpc.demo-vpc.id}"
    
    name = "demo-sg-allow-ssh-and-http"
    description = "Allow SSH and HTTP ingress traffic and all egress"
    
    # Allow Port 22 (SSH)
    ingress {
        from_port = 22
        to_port = 22
        protocol = "TCP"
        cidr_blocks = ["0.0.0.0/0"]
    }
    
    # Allow Port 80 (HTTP)
    ingress {
        from_port = 80
        to_port = 80
        protocol = "TCP"
        cidr_blocks = ["0.0.0.0/0"]
    }
    
    # Allo all outgoing traffix
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

# Create Key pair
resource "aws_key_pair" "przemek" {
    key_name = "przemek-key" 
    public_key = "${var.przemek_key}"
}

# Create EC2 Instance (amzn-ami-hvm - eu-west-1 - ami-e1398992)
# https://aws.amazon.com/marketplace/pp/B00CIYTQTC
resource "aws_instance" "demo-instance" {
    # Provide the type
    instance_type = "t2.nano"    

    # Provide the image ID
    ami = "ami-e1398992"

    # Create the Instance in second AZ and in our subnet
    availability_zone = "eu-west-1b"
    subnet_id = "${aws_subnet.subnet-public.id}"

    # Create Root EBS Volume - 20 GB, SSD backed
    root_block_device {
        volume_size = 20
        volume_type = "gp2"
    }

    # Use our key
    key_name = "${aws_key_pair.przemek.key_name}"

    # Use created Security Group
    vpc_security_group_ids = [
        "${aws_security_group.sg-demo.id}"
    ]
}

# Create EIP
resource "aws_eip" "demo-instance-eip" {
    instance = "${aws_instance.demo-instance.id}"

    vpc = true
}

###### OUTPUTS

# Return EIP on screen
output "eip" {
    value = "${aws_eip.demo-instance-eip.public_ip}"
}


###### EXECUTING CHEF


# Install Chef, and execute cookbook installation
# Use resource that does nothing
resource "null_resource" "simple-chef" {
    # Depends it on the Instance creation
    depends_on = [
      "aws_instance.demo-instance"
    ]

    # Execute commands in remote server
    provisioner "remote-exec" {
        # In order:
        #  - elevate the rights to root
        #  - go to /root
        #  - download and install chef-client
        #  - create cookbooks directory
        #  - download 'learn_chef_httpd' cookbook and unpack it
        #  - execute chef-client in local mode and install cookbook
        inline = [
            "if [ $EUID != 0 ]; then sudo \"$0\" \"$@\"; exit $?; fi",
            "cd /root",
            "curl -L https://www.opscode.com/chef/install.sh | bash",
            "mkdir -p ./cookbooks",
            "curl -L https://supermarket.chef.io/cookbooks/learn_chef_httpd/download | gzip -d | tar -xvvf - -C ./cookbooks",
            "chef-client -z -o learn_chef_httpd"
        ]

        # The connection details
        connection {
            user = "ec2-user"
            host = "${aws_eip.demo-instance-eip.public_ip}"
        }
    }
}

