#!/bin/bash

LOGD() {
    echo -e "\033[1;34m[DEBUG] $*\033[0m"
}

LOGI() {
    echo -e "\033[1;32m[INFO] $*\033[0m"
}

LOGE() {
    echo -e "\033[1;31m[ERROR] $*\033[0m"
}

confirm() {
    read -p "$1" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

ssl_cert_issue() {
    local method=""
    echo -E ""
    LOGD "******使用说明******"
    LOGI "该脚本提供两种方式实现证书签发,证书安装路径均为/root/cert"
    LOGI "方式1:acme standalone mode,需要保持端口开放"
    LOGI "方式2:acme DNS API mode,需要提供Cloudflare Global API Key"
    LOGI "如域名属于免费域名,则推荐使用方式1进行申请"
    LOGI "如域名非免费域名且使用Cloudflare进行解析使用方式2进行申请"
    read -p "请选择你想使用的方式,输入数字1或者2后回车: " method
    LOGI "你所使用的方式为${method}"

    case "${method}" in
        1) ssl_cert_issue_standalone ;;
        2) ssl_cert_issue_by_cloudflare ;;
        *) LOGE "输入无效,请检查你的输入,脚本将退出..."; exit 1 ;;
    esac
}

install_acme() {
    cd ~
    LOGI "开始安装acme脚本..."
    curl https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "acme安装失败"
        return 1
    else
        LOGI "acme安装成功"
    fi
    return 0
}

#method for standalone mode
# shellcheck disable=SC2120
ssl_cert_issue_standalone() {
    #check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "安装 acme 失败，请检查日志"
            exit 1
        fi
    fi
    #install socat second
    if [[ x"${release}" == x"centos" ]]; then
        yum install socat -y
    else
        apt install socat -y
    fi
    if [ $? -ne 0 ]; then
        LOGE "无法安装socat,请检查错误日志"
        exit 1
    else
        LOGI "socat安装成功..."
    fi
    #creat a directory for install cert
    certPath=/root/cert
    if [ ! -d "$certPath" ]; then
        mkdir $certPath
    fi
    #get the domain here,and we need verify it
    local domain=""
    read -p "请输入你的域名:" domain
    LOGD "你输入的域名为:${domain},正在进行域名合法性校验..."
    #here we need to judge whether there exists cert already
    local currentCert=$(~/.acme.sh/acme.sh --list | grep ${domain} | wc -l)
    if [ ${currentCert} -ne 0 ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        LOGE "域名合法性校验失败,当前环境已有对应域名证书,不可重复申请,当前证书详情:"
        LOGI "$certInfo"
        exit 1
    else
        LOGI "域名合法性校验通过..."
    fi
    #get needed port here
    local WebPort=80
    read -p "请输入你所希望使用的端口,如回车将使用默认80端口:" WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "你所选择的端口${WebPort}为无效值,将使用默认80端口进行申请"
    fi
    LOGI "将会使用${WebPort}进行证书申请,请确保端口处于开放状态..."
    #NOTE:This should be handled by user
    #open the port and kill the occupied progress
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d ${domain} --standalone --httpport ${WebPort}
    if [ $? -ne 0 ]; then
        LOGE "证书申请失败,原因请参见报错信息"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书申请成功,开始安装证书..."
    fi
    #install cert


    # 设置证书目录
    cert_dir="/etc/nginx/cert/${domain}"

    # 检查目录是否存在，若不存在则创建该目录
    if [ ! -d "$cert_dir" ]; then
        echo "目录 $cert_dir 不存在，正在创建..."
        mkdir -p "$cert_dir"
    else
        echo "目录 $cert_dir 已存在，跳过创建。"
    fi

    # 安装证书并指定证书存放路径
    ~/.acme.sh/acme.sh --installcert -d "${domain}" \
        --ca-file "${cert_dir}//ca.cer" \
        --cert-file "${cert_dir}/${domain}.cer" \
        --key-file "${cert_dir}/${domain}.key" \
        --fullchain-file "${cert_dir}/fullchain.cer"

    echo "证书和密钥已生成并保存到 ${cert_dir} 目录下。"

    if [ $? -ne 0 ]; then
        LOGE "证书安装失败,脚本退出"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书安装成功,开启自动更新..."
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动更新设置失败,脚本退出"
        ls -lah cert
        chmod 755 $certPath
        exit 1
    else
        LOGI "证书已安装且已开启自动更新,具体信息如下"
        ls -lah cert
        chmod 755 $certPath
    fi

}

#method for DNS API mode
ssl_cert_issue_by_cloudflare() {
    echo -E ""
    LOGD "******使用说明******"
    LOGI "该脚本将使用Acme脚本申请证书,使用时需保证:"
    LOGI "1.知晓Cloudflare 注册邮箱"
    LOGI "2.知晓Cloudflare Global API Key"
    LOGI "3.域名已通过Cloudflare进行解析到当前服务器"
    LOGI "4.该脚本申请证书默认安装路径为/root/cert目录"

    install_acme
    if [ $? -ne 0 ]; then
        LOGE "无法安装acme,请检查错误日志"
        exit 1
    fi

    CF_GlobalKey=""
    CF_AccountEmail=""
    certPath=/root/cert
    if [ ! -d "$certPath" ]; then
        mkdir $certPath
    fi

    LOGD "请设置域名:"
    CF_Domain=""
    while [ -z "$CF_Domain" ]; do
        read -p "Input your domain here: " CF_Domain
        if [ -z "$CF_Domain" ]; then
            LOGE "域名不能为空，请重新输入"
        fi
    done
    LOGD "你的域名设置为:${CF_Domain},正在进行域名合法性校验..."

    # 检查证书是否已存在
    if [ -f ~/.acme.sh/acme.sh ]; then
        local currentCert=$(~/.acme.sh/acme.sh --list | grep -w "${CF_Domain}" | wc -l)
        if [ "${currentCert}" -ne 0 ]; then
            local certInfo=$(~/.acme.sh/acme.sh --list | grep -w "${CF_Domain}")
            LOGE "域名合法性校验失败,当前环境已有对应域名证书,不可重复申请,当前证书详情:"
            LOGI "$certInfo"
            exit 1
        else
            LOGI "域名合法性校验通过..."
        fi
    else
        LOGI "acme.sh 还未安装，跳过证书存在性检查..."
    fi

#    LOGD "请设置API密钥:"
#    read -p "Input your key here:" CF_GlobalKey
#    LOGD "你的API密钥为:${CF_GlobalKey}"
#
#    LOGD "请设置注册邮箱:"
#    read -p "Input your email here:" CF_AccountEmail
#    LOGD "你的注册邮箱为:${CF_AccountEmail}"
    DEFAULT_CF_GlobalKey="f123711180853498fa404a078a3f5226b3416"
    DEFAULT_CF_AccountEmail="liulisanwan@mail.com"

    # 读取API密钥，如果用户未输入，则使用默认值
    LOGD "请设置API密钥:"
    read -p "Input your key here [default: $DEFAULT_CF_GlobalKey]: " CF_GlobalKey
    CF_GlobalKey="${CF_GlobalKey:-$DEFAULT_CF_GlobalKey}"
    LOGD "你的API密钥为:${CF_GlobalKey}"

    # 读取注册邮箱，如果用户未输入，则使用默认值
    LOGD "请设置注册邮箱:"
    read -p "Input your email here [default: $DEFAULT_CF_AccountEmail]: " CF_AccountEmail
    CF_AccountEmail="${CF_AccountEmail:-$DEFAULT_CF_AccountEmail}"
    LOGD "你的注册邮箱为:${CF_AccountEmail}"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if [ $? -ne 0 ]; then
        LOGE "修改默认CA为Lets'Encrypt失败,脚本退出"
        exit 1
    fi

    export CF_Key="${CF_GlobalKey}"
    export CF_Email=${CF_AccountEmail}
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log
    if [ $? -ne 0 ]; then
        LOGE "证书签发失败,脚本退出"
        rm -rf ~/.acme.sh/${CF_Domain}
        exit 1
    else
        LOGI "证书签发成功,安装中..."
    fi
    # 设置证书目录
    cert_dir="/etc/nginx/cert/${CF_Domain}"

    # 检查目录是否存在，若不存在则创建该目录
    if [ ! -d "$cert_dir" ]; then
        echo "目录 $cert_dir 不存在，正在创建..."
        mkdir -p "$cert_dir"
    else
        echo "目录 $cert_dir 已存在，跳过创建。"
    fi

    # 安装证书并指定证书存放路径
    ~/.acme.sh/acme.sh --installcert -d "${CF_Domain}" \
        --ca-file "${cert_dir}/ca.cer" \
        --cert-file "${cert_dir}/${CF_Domain}.cer" \
        --key-file "${cert_dir}/${CF_Domain}.key" \
        --fullchain-file "${cert_dir}/fullchain.cer"

    echo "证书和密钥已生成并保存到 ${cert_dir} 目录下。"
#
#    ~/.acme.sh/acme.sh --installcert -d ${CF_Domain} -d *.${CF_Domain} --ca-file /root/cert/ca.cer \
#        --cert-file /root/cert/${CF_Domain}.cer --key-file /root/cert/${CF_Domain}.key \
#        --fullchain-file /root/cert/fullchain.cer
    if [ $? -ne 0 ]; then
        LOGE "证书安装失败,脚本退出"
        rm -rf ~/.acme.sh/${CF_Domain}
        exit 1
    else
        LOGI "证书安装成功,开启自动更新..."
    fi

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动更新设置失败,脚本退出"
        ls -lah cert
        chmod 755 $certPath
        exit 1
    else
        LOGI "证书已安装且已开启自动更新,具体信息如下"
        ls -lah cert
        chmod 755 $certPath
    fi
}
ssl_cert_issue
