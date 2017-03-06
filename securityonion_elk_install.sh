#!/bin/bash
# Security Onion with ELK
#
# THANKS
# Special thanks to Justin Henderson for his Logstash configs and installation guide!
# Forked from:
# https://github.com/SMAPPER/Logstash-Configs/blob/master/securityonion_elk_install.txt
#
# CHANGELOG
# 2017-03-04
# Replaced Oracle Java with OpenJDK
# Removed CIF and frequency analysis for now
# Updated ELK components to latest versions compatible with openjdk-7
#
# 2017-03-06
# Replaced nxlog with our existing syslog-ng
# Changed openjdk-7-jre to openjdk-7-jre-headless
# Removed Setup instructions
# Added note assuming 14.04.5.2 ISO image with Setup run in Evaluation Mode
#
# TODO
# Add authentication proxy for Kibana
# Add Kibana plugin to pivot to CapMe
# Add custom visualizations and dashboards

# Check for prerequisites
[ "$(id -u)" -ne 0 ] && echo "This script must be run using sudo!" && exit 1

if [ ! -f /etc/nsm/securityonion.conf ]; then
	echo "/etc/nsm/securityonion.conf not found!  Exiting!"
	exit 1
fi

if [ ! grep -i "ELSA=YES" /etc/nsm/securityonion.conf > /dev/null 2>&1 ]; then
	echo "Looks like ELSA isn't current enabled.  Exiting!"
	exit 1
fi

clear
cat << EOF 
This script will install ELK and configure syslog-ng to send logs to ELK.

This script assumes that you're running the latest Security Onion 14.04.5.2 ISO image
and that you've already run through Setup, choosing Evaluation Mode to enable ELSA.

WARNINGS AND DISCLAIMERS
This script is PRE-ALPHA and UNSUPPORTED!
If this script breaks your system, you get to keep both pieces!
Do NOT run this on a production system that you care about!
Kibana has no authentication by default, so do NOT run this on a system with sensitive data!
(We will be adding an authentication proxy in the future.)
This script should only be run on a TEST box with TEST data!
 
HARDWARE REQUIREMENTS
ELK requires more hardware than ELSA, so for a test VM, you'll probably want at least 4GB of RAM.
 
Once you've read all of the WARNINGS and DISCLAIMERS above, please type AGREE to proceed:
EOF
read input
if [ "$INPUT" != "AGREE" ] ; then exit 0; fi

# Make a directory to store downloads
DIR="/tmp/elk"
mkdir $DIR
cd $DIR

echo "* Installing OpenJDK..."
sudo apt-get update
sudo apt-get install openjdk-7-jre-headless

echo "* Downloading ELK packages..."
wget https://download.elastic.co/elasticsearch/release/org/elasticsearch/distribution/deb/elasticsearch/2.4.4/elasticsearch-2.4.4.deb
wget https://download.elastic.co/logstash/logstash/packages/debian/logstash-2.4.1_all.deb
wget https://download.elastic.co/kibana/kibana/kibana-4.6.4-amd64.deb
wget -qO - https://packages.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -

echo "* Installing ELK packages..."
sudo dpkg -i /tmp/elk/elasticsearch-*.deb
sudo dpkg -i /tmp/elk/logstash-*_all.deb
sudo dpkg -i /tmp/elk/kibana-*-amd64.deb

echo "* Downloading GeoIP data..."
sudo mkdir /usr/local/share/GeoIP
cd /usr/local/share/GeoIP
sudo wget http://geolite.maxmind.com/download/geoip/database/GeoLiteCity.dat.gz
sudo wget http://geolite.maxmind.com/download/geoip/database/GeoLiteCountry/GeoIP.dat.gz
sudo wget http://geolite.maxmind.com/download/geoip/database/GeoIPv6.dat.gz
sudo wget http://geolite.maxmind.com/download/geoip/database/GeoLiteCityv6-beta/GeoLiteCityv6.dat.gz
sudo wget http://download.maxmind.com/download/geoip/database/asnum/GeoIPASNum.dat.gz
sudo gunzip *.gz
cd $DIR

echo "* Installing ELK plugins..."
sudo apt-get -y install python-pip
sudo pip install elasticsearch-curator
sudo /usr/share/elasticsearch/bin/plugin install lmenezes/elasticsearch-kopf
sudo /opt/logstash/bin/logstash-plugin install logstash-filter-translate
sudo /opt/logstash/bin/logstash-plugin install logstash-filter-tld
sudo /opt/logstash/bin/logstash-plugin install logstash-filter-elasticsearch
sudo /opt/logstash/bin/logstash-plugin install logstash-filter-rest
sudo /opt/kibana/bin/kibana plugin --install elastic/sense
sudo /opt/kibana/bin/kibana plugin --install prelert_swimlane_vis -u https://github.com/prelert/kibana-swimlane-vis/archive/v0.1.0.tar.gz
git clone https://github.com/oxalide/kibana_metric_vis_colors.git
sudo apt-get install zip -y
zip -r kibana_metric_vis_colors kibana_metric_vis_colors
sudo /opt/kibana/bin/kibana plugin --install metric-vis-colors -u file://$DIR/kibana_metric_vis_colors.zip
sudo /opt/kibana/bin/kibana plugin -i kibana-slider-plugin -u https://github.com/raystorm-place/kibana-slider-plugin/releases/download/v0.0.2/kibana-slider-plugin-v0.0.2.tar.gz
sudo /opt/kibana/bin/kibana plugin --install elastic/timelion
sudo /opt/kibana/bin/kibana plugin -i kibana-html-plugin -u https://github.com/raystorm-place/kibana-html-plugin/releases/download/v0.0.3/kibana-html-plugin-v0.0.3.tar.gz

echo "* Configuring ElasticSearch..."
FILE="/etc/elasticsearch/elasticsearch.yml"
echo "network.host: 127.0.0.1" | sudo tee -a $FILE
echo "cluster.name: securityonion" | sudo tee -a $FILE
echo "index.number_of_replicas: 0" | sudo tee -a $FILE

echo "* Installing logstash config files..."
sudo apt-get install git -y
git clone https://github.com/dougburks/Logstash-Configs.git
sudo cp -rf Logstash-Configs/configfiles/*.conf /etc/logstash/conf.d/
sudo cp -rf Logstash-Configs/dictionaries /lib/
sudo cp -rf Logstash-Configs/grok-patterns /lib/

echo "* Enabling ELK..."
sudo update-rc.d elasticsearch defaults
sudo update-rc.d logstash defaults
sudo update-rc.d kibana defaults

echo "* Starting ELK..."
sudo service elasticsearch start
sudo service logstash start
sudo service kibana start

echo "* Reconfiguring syslog-ng to send logs to ELK..."
FILE="/etc/syslog-ng/syslog-ng.conf"
sudo cp $FILE $FILE.elsa
sudo sed -i '/^destination d_elsa/a destination d_elk { tcp("127.0.0.1" port(6050) template("$(format-json --scope selected_macros --scope nv_pairs --exclude DATE --key ISODATE)\n")); };' $FILE
sudo sed -i 's/log { destination(d_elsa); };/log { destination(d_elk); };/' $FILE
sudo sed -i '/rewrite(r_host);/d' $FILE
sudo sed -i '/rewrite(r_cisco_program);/d' $FILE
sudo sed -i '/rewrite(r_snare);/d' $FILE
sudo sed -i '/rewrite(r_from_pipes);/d' $FILE
sudo sed -i '/rewrite(r_pipes);/d' $FILE
sudo sed -i '/parser(p_db);/d' $FILE
sudo sed -i '/rewrite(r_extracted_host);/d' $FILE
sudo service syslog-ng restart

echo "* Replaying pcaps in /opt/samples/ to create logs..."
for i in /opt/samples/*.pcap /opt/samples/markofu/*.pcap /opt/samples/mta/*.pcap; do
	echo $i
	sudo tcpreplay -ieth1 -M10 $i >/dev/null 2>&1
done

cat << EOF

All done!

At this point, you should be able to access Kibana:
http://localhost:5601
You should see Bro logs and Snort alerts (although the Snort alerts may not be parsed properly right now)

For additional (optional) configuration, please see:
https://github.com/dougburks/Logstash-Configs/blob/master/securityonion_elk_install.txt
EOF