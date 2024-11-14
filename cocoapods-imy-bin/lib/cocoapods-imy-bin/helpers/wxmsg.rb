#!/usr/bin/ruby
#encoding: utf-8

# zhuanzhuan
# Created by ChildhoodAndy on 2020.04.10
# Copyright (c) 2020年 转转. All rights reserved.
#

require 'uri'
require 'net/http'
require 'json'
require 'set'

module CBin
  # 企业微信 Robot 消息发送
  class WXMsg
    def self.send_wechat_group_msg(content)
      api_endpoint = 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=91968679-2fd5-4a70-87f8-8d0a05d95143'
      uri = URI.parse(api_endpoint)
      payload = build_payload(content)

      send_request(uri, payload)
    end

    def self.build_payload(content)
      {
        'msgtype' => 'text',
        'text' => {
          'content' => content
          # 'mentioned_list' => ['@all']
        }
      }
    end

    def self.send_request(uri, payload)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        header = {'Content-Type': 'application/json'}
        req = Net::HTTP::Post.new(uri, header)
        req.body = payload.to_json.force_encoding('UTF-8')
        http.request(req)
      end
    end
  end
end

# Testing
# CBin::WXMsg.send_wechat_group_msg("Masonry二进制构建结果\n====Masonry | 1.2.3二进制组件制作完成！\n=========auto success")
