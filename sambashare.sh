# 1. Install everything
sudo pacman -Syu --needed samba avahi nss-mdns

# 2. Create shared folder
sudo mkdir -p /mnt/shared
sudo chown nobody:nobody /mnt/shared
sudo chmod 777 /mnt/shared

# 3. Write perfect smb.conf (guest + discovery everywhere)
sudo tee /etc/samba/smb.conf > /dev/null <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = Samba Server %v
   netbios name = archbox
   security = user
   map to guest = Bad User
   dns proxy = no
   server min protocol = SMB2
   server max protocol = SMB3
   local master = yes
   preferred master = yes
   os level = 65
   multicast dns register = yes
   fruit:mdns = yes
   zeroconf = yes

[Shared]
   path = /mnt/shared
   browsable = yes
   writable = yes
   guest ok = yes
   read only = no
   create mask = 0644
   directory mask = 0755
EOF

# 4. Enable services + firewall
sudo systemctl enable --now smb nmb avahi-daemon
sudo firewall-cmd --permanent --add-service=samba && sudo firewall-cmd --reload 2>/dev/null || sudo ufw allow samba 2>/dev/null || true

# 5. Fix name resolution on THIS machine (for clients)
sudo sed -i 's/hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns mdns/' /etc/nsswitch.conf

# 6. Final check
testparm -s && systemctl status smb nmb avahi-daemon --no-pager
echo "SUCCESS! Share is live."
EOF


## Simplified use kde package

# 1. Install
sudo pacman -S samba kdenetwork-filesharing

# 2. Enable usershares (required for GUI)
sudo mkdir -p /var/lib/samba/usershares
sudo groupadd -r sambashare
sudo chown root:sambashare /var/lib/samba/usershares
sudo chmod 1770 /var/lib/samba/usershares
sudo gpasswd sambashare -a $USER   # add your user

# 3. Add to smb.conf [global]
sudo nano /etc/samba/smb.conf
# Add these lines:
   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = yes
   usershare owner only = yes

# 4. Restart
sudo systemctl restart smb nmb

# 5. Re-login or restart Dolphin
