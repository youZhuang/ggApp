local skynet = require "skynet"
local socket = require "skynet.socket"
local crypt = require "skynet.crypt"
local lkcp = require "lkcp"
local HandShake = require "app.client.handshake"
local config = require "app.config.custom"
local codec = require "app.codec.codec"

--  kcp会话管理,格式: 1byte协议类别+具体协议参数
--  协议类别:
--  SYN = 1     // 连接(connect)
--      4byte 主动连接方连接ID
--  ACK = 2     // 接受连接(accept)
--      4byte 接受连接方ID
--      4byte 被接受方连接ID
--  FIN = 3     // 断开连接(disconnect)
--      4byte 主动断开方连接ID
--      4byte 被动断开方连接ID
--      4byte errcode
--  MSG = 4     // 消息包(send/recv)
--      4byte 发消息方连接ID
--      kcp_msg
--
local KcpProtoType = {
    SYN = 1,
    ACK = 2,
    FIN = 3,
    MSG = 4,
}

local function getms()
    return math.floor(skynet.time() * 1000) & 0xffffffff
end


local kcp = {}
local mt = {__index = kcp}

function kcp.new(opts)
    local codecobj = codec.new(config.proto)
    local self = {
        linktype = "kcp",
        linkid = nil,
        endpoint_linkid = nil,
        wait_proto = {},
        codec = codecobj,
        handler = opts.handler,
    }
    self.handShake = HandShake.new(self)
    if not config.handshake then
        self.handShake.result = "OK"
    end
    return setmetatable(self,mt)
end

function kcp:udp_send_connect(cnt)
    cnt = cnt or 1
    local buffer = string.pack("<Bi4",KcpProtoType.SYN,self.linkid)
    socket.write(self.linkid,buffer)
    cnt = cnt - 1
    if cnt > 0 then
        skynet.timeout(50,function ()
            self:udp_send_connect(cnt)
        end)
    end
end

function kcp:udp_send_close(cnt)
    cnt = cnt or 1
    local errcode = 0
    local buffer = string.pack("<Bi4i4i4",KcpProtoType.FIN,self.linkid,self.endpoint_linkid,errcode)
    socket.write(self.linkid,buffer)
    cnt = cnt - 1
    if cnt > 0 then
        skynet.timeout(50,function ()
            self:udp_send_close(cnt)
        end)
    else
        socket.close(self.linkid)
    end
end

function kcp:udp_send_kcpmsg(buffer)
    local buffer = string.pack("<Bi4",KcpProtoType.MSG,self.linkid) .. buffer
    socket.write(self.linkid,buffer)
end

function kcp:connect(host,port)
    self.linkid = socket.udp(function (msg,from)
        self:dispatch_message(from,msg)
    end)
    socket.udp_connect(self.linkid,host,port)
    self:udp_send_connect(10)
end

function kcp:dispatch_message(from,msg)
    local ctrl = string.unpack("<B",msg,1)
    if ctrl == KcpProtoType.ACK then
        self:onconnect(msg)
    elseif ctrl == KcpProtoType.FIN then
        self:onclose(msg)
    elseif ctrl == KcpProtoType.MSG then
        self:recv_message(msg)
    end
end

function kcp:onconnect(msg)
    if self.kcp then
        return
    end
    local len = #msg
    if len < 9 then
        return
    end
    -- ACK
    local endpoint_linkid = string.unpack("<i4",msg,2)
    local my_linkid = string.unpack("<i4",msg,6)
    assert(my_linkid == self.linkid)
    self.endpoint_linkid = endpoint_linkid
    self.kcp = lkcp.lkcp_create(self.endpoint_linkid,function (buffer)
        self:udp_send_kcpmsg(buffer)
    end)
    self.kcp:lkcp_nodelay(1,10,2,1)
    self.kcp:lkcp_wndsize(256,256)
    self.kcp:lkcp_setmtu(470)
    skynet.fork(function ()
        while true do
            skynet.sleep(20)
            self:on_tick(getms())
        end
    end)
    if self.handler.onconnect then
        self.handler.onconnect(self)
    end
    if self.handShake.result then
        if self.handler.onhandshake then
            self.handler.onhandshake(self,self.handShake.result)
        end
    end
end

function kcp:on_tick(ms)
    if not self.kcp then
        return
    end
    self.kcp:lkcp_update(ms)
end

function kcp:onclose(msg)
    local len = #msg
    if len < 9 then
        return
    end
    local endpoint_linkid = string.unpack("<i4",msg,2)
    local my_linkid = string.unpack("<i4",msg,6)
    --local errcode = string.unpack("<i4",msg,10)
    assert(self.linkid == my_linkid)
    assert(self.endpoint_linkid == endpoint_linkid)
    self:close()
end

function kcp:recv_message(msg)
    local len = #msg
    if len < 9 then
        return
    end
    local endpoint_linkid = string.unpack("<i4",msg,2)
    local my_linkid = string.unpack("<i4",msg,6)
    msg = string.sub(msg,6)
    assert(self.endpoint_linkid == endpoint_linkid)
    self.kcp:lkcp_input(msg)
    while true do
        local len,msg = self.kcp:lkcp_recv()
        if len > 0 then
            self:onmessage(msg)
        else
            break
        end
    end
end

function kcp:say(...)
    skynet.error(string.format("[linktype=%s,linkid=%s]",self.linktype,self.linkid),...)
end

function kcp:onmessage(msg)
    if not self.handShake.result then
        local ok,err = self.handShake:doHandShake(msg)
        if not ok then
            self:close()
        end
        self:say(string.format("op=handShaking,ok=%s,err=%s,step=%s",ok,err,self.handShake.step))
        if self.handShake.result then
           self:say(string.format("op=handShake,encryptKey=%s,result=%s",self.handShake.encryptKey,self.handShake.result))
           if self.handler.onhandshake then
               self.handler.onhandshake(self,self.handShake.result)
           end
        end
        return
    end
    msg = self.handShake:decrypt(msg)
    local message = self.codec:unpack_message(msg)
    if self.handler.onmessage then
        self.handler.onmessage(self,message)
    end
    local protoname = message.cmd
    local callback = self:wakeup(protoname)
    if callback then
        callback(self,message)
    end
end

function kcp:send(message)
    local bin = self.codec:pack_message(message)
    bin = self.handShake:encrypt(bin)
    self:rawSend(bin)
end

function kcp:rawSend(bin)
    self.kcp:lkcp_send(bin)
    self.kcp:lkcp_flush()
end

function kcp:send_request(protoname,request,callback)
    local session
    if callback then
        self.session = self.session + 1
        session = self.session
        self.sessions[session] = callback
    end
    local message = {
        type = 1,
        cmd = protoname,
        args = request,
        session = session,
    }
    self:send(message)
end

function kcp:send_response(protoname,response,session)
    local message = {
        type = 2,
        cmd = protoname,
        args = response,
        session = session,
    }
    self:send(message)
end

function kcp:wait(protoname,callback)
    if not self.wait_proto[protoname] then
        self.wait_proto[protoname] = {}
    end
    table.insert(self.wait_proto[protoname],callback)
end

function kcp:wakeup(protoname)
    if not self.wait_proto[protoname] then
        return nil
    end
    return table.remove(self.wait_proto[protoname],1)
end

kcp.ignore_one = kcp.wakeup

function kcp:close()
    if self.closed then
        return
    end
    self.closed = true
    self:udp_send_close(3)
    if self.handler.onclose then
        self.handler.onclose(self)
    end
end

return kcp
