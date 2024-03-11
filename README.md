<!DOCTYPE markdown>
# Devmon Introduction

Devmon is an SNMP monitoring tool developed to enhance the SNMP monitoring capabilities of a server running Xymon monitoring software. It's designed to efficiently monitor a significant number of devices, providing both graphing and alerting functionalities.

![Devmon's Current Overview](devmon_current_status.png)

Discover more through [screenshots](https://wiki.ubiquitous-network.ch/doku.php?id=en:devmon:screenshots).

## Recent Enhancements (September 2023)
- **New Table Alignment Feature**: Credit to W. Nelis
- **Resolved Issues**: Various bug fixes.

## Enhancing SNMPwalk Engine (July 2023)

- **Smarter Retry Logic and Efficient SNMPwalk** :
  - Addresses memory leaks: no more dying fork
  - Utilizes "snmpgetbulk" and manages partial responses.
- **Enhanced Performance**:
  - Improves monitoring speed, particularly for slow devices.
- **Upgrade**: Recommended 
- **Notes**:
  - **Engine Transition**: Default engine switched to SNMP_Session (Pure Perl) for improved operation.
  - **SNMPv3**: Still dependent on external "C" library; partial retries not fully implemented.

## Ongoing Initiatives and Future Directions
- **Engagement and Roadmap**: Join our [GitHub discussions](https://github.com/bonomani/devmon/discussions) and view [issues](https://github.com/bonomani/devmon/issues) for the latest updates and to participate in our community.
- **Code Quality and Practices**: Focusing on implementing modern coding standards and practices.
- **Documentation Update**: Making information more accessible and user-friendly.
- **IPv6 Support**: Preparing Devmon for future network technologies.
- **Enhancing Clustering Support**: To accommodate diverse and large-scale network environments.
- **Optimizing Discovery and Ping Tests**: Striving for better stability and performance.

## Key Features and Technologies
Devmon utilizes technologies like Xymon, SNMP, Perl5, and MySQL to provide:
- **Efficient Polling**: Through a multithreaded engine that allows quick querying of numerous devices.
- **Automated Device Discovery**: For easy integration and management of network devices.
- **Scalable Solutions**: Catering to both small and large network environments with potential for cluster configurations.

## Getting Started
Requirements for running Devmon include:
- A Perl-compatible system for script execution. See the [INSTALLATION.md](https://github.com/bonomani/devmon/blob/main/docs/INSTALLATION.md) guide in our docs.
- Xymon for displaying monitoring results. Ensure at least one host is set up in Xymon that matches a Devmon template for effective polling.

## Project Status
- **Under Active Development**: We are currently working with a pre-release version, indicating that the software is still in the experimental stages

## Learning More
- [Devmon Wiki](http://wiki.ubiquitous-network.ch/doku.php?id=en:devmon): A valuable resource for developers with best practices and detailed documentation.
- [Visual Gallery](https://wiki.ubiquitous-network.ch/doku.php?id=en:devmon:screenshots): Get insights into what Devmon offers through our screenshot collection.

## Reach Out
For inquiries, feedback, or further information, don't hesitate to [contact](https://ubiquitous-network.ch/contact/) us. We're always looking for ways to improve and welcome your input.
```
