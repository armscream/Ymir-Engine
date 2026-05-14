# Vulkan SDK Environment Variable Setup Script
# Run this script as Administrator to set Vulkan SDK variables system-wide


$VulkanSDKVer = "C:\VulkanSDK\1.4.341.1"

# Set VULKAN_SDK
[Environment]::SetEnvironmentVariable("VULKAN_SDK", $VulkanSDKVer, "Machine")

# Add Vulkan SDK Bin to PATH if not already present
$oldPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$newBin = "$VulkanSDKVer\Bin"
if ($oldPath -notlike "*$newBin*") {
    [Environment]::SetEnvironmentVariable("Path", "$oldPath;$newBin", "Machine")
}

# Set VK_LAYER_PATH
[Environment]::SetEnvironmentVariable("VK_LAYER_PATH", "$VulkanSDKVer\Bin\config\explicit_layer.d", "Machine")

# Set INCLUDE and LIB (optional, for compiling/linking)
[Environment]::SetEnvironmentVariable("INCLUDE", "$VulkanSDKVer\Include", "Machine")
[Environment]::SetEnvironmentVariable("LIB", "$VulkanSDKVer\Lib", "Machine")

Write-Host "Vulkan SDK environment variables set system-wide. Please restart your computer or log out/in for changes to take effect."
