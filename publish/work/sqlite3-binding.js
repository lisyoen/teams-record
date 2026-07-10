const path=require('path');
const knox=process.env.KNOX_ROOT||'C:\\mySingle\\KnoxTeams';
module.exports=require(path.join(knox,'resources','app.asar.unpacked','node_modules','@journeyapps','sqlcipher','lib','binding','napi-v6-win32-ia32','node_sqlite3.node'));
