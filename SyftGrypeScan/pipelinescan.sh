#!/bin/bash
# สั่งให้สคริปต์หยุดทำงานทันทีหากมีคำสั่งใดทำงานผิดพลาด (ยกเว้นขั้นตอนที่ตั้งใจ)
set -e

echo "========================================="
echo " Starting SSDLC Automation Pipeline"
echo "========================================="

# 1. ตรวจสอบข้อมูลนำเข้าที่จำเป็น
if [ -z "$GIT_REPO_URL" ] || [ -z "$DTRACK_URL" ] || [ -z "$DTRACK_API_KEY" ] || [ -z "$DTRACK_PROJECT_ID" ]; then
    echo "Error: Missing required environment variables."
    echo "Required: GIT_REPO_URL, DTRACK_URL, DTRACK_API_KEY, DTRACK_PROJECT_ID"
    exit 1
fi

# 2. Clone Git Repository
echo "--> 1/4 Cloning repository: $GIT_REPO_URL"
rm -rf /workspace && mkdir -p /workspace
git clone "$GIT_REPO_URL" /workspace
cd /workspace

# 3. Run Syft (Generate SBOM)
echo "--> 2/4 Generating SBOM with Syft..."
syft dir:. -o cyclonedx-json=/tmp/sbom.json
echo "SBOM generated successfully at /tmp/sbom.json"

# 4. Run Grype (Local Vulnerability Report)
echo "--> 3/4 Scanning vulnerabilities with Grype..."
# ไม่ใช้ set -e ชั่วคราว เผื่อกรณีต้องการให้ผ่านแม้เจอช่องโหว่ (หรือจะให้ขาดเลยก็พึ่งพา --fail-on)
set +e
grype /tmp/sbom.json
GRYPE_STATUS=$?
set -e
echo "Grype scan completed with status $GRYPE_STATUS"

# 5. Upload Result to OWASP Dependency-Track
echo "--> 4/4 Uploading SBOM to OWASP Dependency-Track..."
RESPONSE=$(curl -s -w "%{http_code}" -X "POST" "$DTRACK_URL/api/v1/bom" \
     -H "Content-Type: multipart/form-data" \
     -H "X-Api-Key: $DTRACK_API_KEY" \
     -F "project=$DTRACK_PROJECT_ID" \
     -F "bom=@/tmp/sbom.json")

HTTP_STATUS="${RESPONSE:${#RESPONSE}-3}"

if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
    echo "Successfully uploaded SBOM to Dependency-Track (HTTP $HTTP_STATUS)"
else
    echo "Error: Failed to upload SBOM (HTTP $HTTP_STATUS)"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "========================================="
echo " Pipeline Finished Successfully!"
echo "========================================="