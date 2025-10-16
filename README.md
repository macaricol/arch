# Project Overview

This README provides detailed instructions on how to use the scripts included in this repository: `install.sh`, `post_reboot.sh`, and `test_sddm_theme.sh`. Each script serves a specific purpose in the setup and configuration process of the system.

## Script Overviews

### install.sh

This script is responsible for the initial installation of the system. It handles the drive selection, partitioning, and installation of necessary packages. 

### post_reboot.sh

After the initial installation and reboot, this script configures the system settings and applies user preferences. It sets up various system components and ensures everything is in place for the user.

### test_sddm_theme.sh

This script tests different SDDM themes to help users choose their preferred login screen appearance.

## Step-by-Step Usage

### Using install.sh
1. **Preparation**: Before running the script, ensure you have a backup of your data.
2. **Execution**: Run the script with the command `bash install.sh`. Follow the prompts to select the drive and configure partitioning.
3. **Installation**: Allow the script to complete the installation process. This may take some time. 

### Using post_reboot.sh
1. **Post-Reboot**: After rebooting, log in to your system.
2. **Execution**: Run the command `bash post_reboot.sh` to apply configurations.
3. **Completion**: Wait for the script to finish configuring your system settings.

### Using test_sddm_theme.sh
1. **Execution**: Run `bash test_sddm_theme.sh` to start testing themes.
2. **Selection**: Follow the prompts to select and preview different themes.
3. **Finalization**: Choose a theme that you like and apply it.

## Customization

Each script can be customized by editing parameters directly within the script files. Review the code for specific options that can be modified.

## Warnings

- **Data Loss**: Running `install.sh` will format the selected drive. Ensure you have backed up any important data.
- **System Compatibility**: Ensure that your hardware is compatible with the installation scripts.

## Contribution Guidelines

We welcome contributions! Please follow these guidelines:
1. **Fork the repository**: Create your own copy of the repository.
2. **Make changes**: Implement your changes or improvements.
3. **Submit a pull request**: Describe your changes clearly and provide any relevant information.

## Safety Recommendations

- Always back up your data before running installation scripts.
- Test scripts in a virtual environment if possible before deploying on physical hardware.

## Conclusion

This README serves as a comprehensive guide for utilizing the scripts in this repository. Follow the instructions carefully to ensure a smooth installation and configuration process.