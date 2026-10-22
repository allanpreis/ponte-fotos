from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def respond(self,body,status=200):
        data=json.dumps(body).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
    def read(self): return json.loads(self.rfile.read(int(self.headers['Content-Length'])))
    def do_GET(self):
        assert self.path=='/api/albums'; self.respond([{'id':'album-1','albumName':'Teste','shared':False}])
    def do_POST(self):
        assert self.path=='/api/albums'; assert self.read()=={'albumName':'Teste'}
        self.respond({'id':'album-1','albumName':'Teste'},201)
    def do_PUT(self):
        body=self.read()
        if self.path=='/api/albums/album-1/assets':
            assert body=={'ids':['photo-1']}; self.respond([{'id':'photo-1','success':True}])
        else:
            assert self.path=='/api/assets/photo-1'; assert body=={'dateTimeOriginal':'1970-01-01T00:00:00Z','latitude':-23.5,'longitude':-46.5}; self.respond({})
HTTPServer(('127.0.0.1',18761),Handler).serve_forever()
