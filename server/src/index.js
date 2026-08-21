import cors from 'cors';
import express from 'express';
import { createServer } from 'node:http';
import os from 'node:os';
import { Server } from 'socket.io';
import { createAuthRouter, requireAuth } from './auth.js';
import { PORT } from './config.js';
import { createRoomsRouter } from './rooms.js';
import { searchRouter } from './search.js';
import { registerSocket } from './socket.js';
import { uploadRouter, uploadsDir } from './upload.js';
import { createUsersRouter } from './users.js';

const app = express();
app.use(cors());
app.use(express.json());

const httpServer = createServer(app);
const io = new Server(httpServer, { cors: { origin: '*' } });

app.use('/auth', createAuthRouter(io));
app.use('/api', requireAuth, uploadRouter);
app.use('/api', requireAuth, createUsersRouter(io));
app.use('/api', requireAuth, createRoomsRouter(io));
app.use('/api', requireAuth, searchRouter);
app.use('/uploads', express.static(uploadsDir));

app.get('/health', (req, res) => res.json({ ok: true }));

registerSocket(io);

httpServer.listen(PORT, () => {
  const lanAddresses = Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);

  console.log(`메신저 서버 실행 중 (포트 ${PORT})`);
  console.log('같은 와이파이의 다른 기기에서 접속할 주소:');
  for (const addr of lanAddresses) console.log(`  http://${addr}:${PORT}`);
});
