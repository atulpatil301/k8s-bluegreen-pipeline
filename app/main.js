// app/main.js
const express = require('express');
const app = express();
const port = 3000;
const appVersion = process.env.APP_VERSION || '1.0.0';
const environment = process.env.NODE_ENV || 'development';

app.get('/', (req, res) => {
  res.send(`Hello from Node.js App! Version: ${appVersion}, Environment: ${environment}. Deployed at: ${new Date().toISOString()}\n`);
});

app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

app.listen(port, () => {
  console.log(`Node.js app listening at http://localhost:${port}`);
  console.log(`App Version: ${appVersion}`);
  console.log(`Environment: ${environment}`);
});