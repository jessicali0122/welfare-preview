const E = encodeURIComponent;

function openUrl(url, makeActive = false){
  if (typeof chrome !== 'undefined' && chrome.tabs && chrome.tabs.create){
    chrome.tabs.create({ url, active: makeActive });
  } else {
    window.open(url, '_blank');
  }
}

function calcDelay(count){
  if(count <= 1) return 0;
  return Math.min(400, Math.max(120, Math.round(6000 / count)));
}

const platforms = [
  { id:'momo',     name:'momo',     color:'242,0,202',   url:q=>`https://www.momoshop.com.tw/search/searchShop.jsp?keyword=${E(q)}` },
  { id:'shopee',   name:'蝦皮',     color:'247,67,46',   url:q=>`https://shopee.tw/search?keyword=${E(q)}` },
  { id:'pchome',   name:'PChome',   color:'234,23,23',   url:q=>`https://24h.pchome.com.tw/search/?q=${E(q)}` },
  { id:'yahoo',    name:'YAHOO',    color:'157,97,255',  url:q=>`https://tw.buy.yahoo.com/search/product?p=${E(q)}` },
  { id:'etmall',   name:'東森',     color:'182,0,5',     url:q=>`https://www.etmall.com.tw/Search?keyword=${E(q)}` },
  { id:'cyberbiz', name:'CYBERBIZ', color:'4,50,141',    url:null }
];

const brands = [
  { id:'damo',      name:'達摩本草',  color:'9,60,113',    official:'https://www.damokampo.com/',      shopeeShopId:'60224952',  searchUrl:q=>`https://www.damokampo.com/search?q=${E(q)}` },
  { id:'petage',    name:'毛孩時代',  color:'61,159,147',  official:'https://www.petstimes.com.tw/',   shopeeShopId:'45057582',  searchUrl:q=>`https://www.petstimes.com.tw/search?q=${E(q)}` },
  { id:'yuxi',      name:'御熹堂',    color:'183,28,34',   official:'https://www.yunxi.com.tw/',       shopeeShopId:'550900642', searchUrl:q=>`https://www.yunxi.com.tw/search?q=${E(q)}` },
  { id:'powerhero', name:'PowerHero', color:'51,51,51',    official:'https://www.powerhero.com.tw/',   shopeeShopId:'497638840', searchUrl:q=>`https://www.powerhero.com.tw/search?q=${E(q)}` },
  { id:'ourpet',    name:'奧沛',      color:'13,111,160',  official:'https://www.ourpet.com.tw/',      shopeeShopId:'1479499180', searchUrl:q=>`https://www.ourpet.com.tw/search?q=${E(q)}` },
  { id:'fumu',      name:'芙木之光',  color:'196,113,92',  official:'https://www.inalumie.com/',       shopeeShopId:'1082322279', searchUrl:q=>`https://www.inalumie.com/search?q=${E(q)}` },
  { id:'oshima',    name:'大島生醫',  color:'184,146,90',  official:'https://www.oshimashop.com.tw/',  shopeeShopId:'1303992164', searchUrl:q=>`https://www.oshimashop.com.tw/search?q=${E(q)}` },
  { id:'xxs',       name:'XXS',       color:'255,75,127',  official:'https://www.xxs.com.tw/',         shopeeShopId:'1426145721', searchUrl:q=>`https://www.xxs.com.tw/search?q=${E(q)}` },
  { id:'tryme',     name:'TRYME',     color:'248,167,158', official:'https://www.tryme.com.tw/',       shopeeShopId:'50231292',  searchUrl:q=>`https://www.tryme.com.tw/search?q=${E(q)}` },
  { id:'yakupet',   name:'優固倍',    color:'96,38,158',   official:'https://www.yakupet.com.tw/',     shopeeShopId:'1541818172', searchUrl:q=>`https://www.yakupet.com.tw/search?q=${E(q)}` }
];

const specialPlatforms = [
  { id:'tsa',        name:'短蝦',     color:'247,100,30',
    url:q=>`https://shopee.tw/search?keyword=${E(q)}&shop=1451389614` },
  { id:'shopeemart', name:'蝦皮超市', color:'234,108,0',
    url:q=>`https://shopee.tw/mall/search?keyword=${E(q)}&shop=50662979` }
];

const selP  = new Set();
const selB  = new Set();
const selSP = new Set();
const selSB = new Set();
let   spMode = 'keyword';

function renderGroup(items, sel, gridId, blockId){
  const grid = document.getElementById(gridId);
  grid.innerHTML = '';
  items.forEach(item=>{
    const btn = document.createElement('button');
    btn.className = 'chip' + (sel.has(item.id) ? ' active' : '');
    btn.dataset.id = item.id;
    btn.textContent = item.name;
    if(item.color) btn.style.setProperty('--chip-clr', item.color);

    btn.onclick = ()=>{
      sel.has(item.id) ? sel.delete(item.id) : sel.add(item.id);
      renderGroup(items, sel, gridId, blockId);
    };

    if(item.official){
      setupLongPress(btn, item);
    }

    grid.appendChild(btn);
  });
  updateCount();
  updateSelectAllBtns();
}

function selectAll(type){
  if(type === 'platform')  { platforms.forEach(p => selP.add(p.id));  renderGroup(platforms, selP, 'platformGrid', 'platformBlock'); }
  else if(type === 'brand'){ brands.forEach(b => selB.add(b.id));     renderGroup(brands,    selB, 'brandGrid',    'brandBlock'); }
  else if(type === 'spBrand'){ brands.forEach(b => selSB.add(b.id)); renderGroup(brands, selSB, 'spBrandGrid'); }
}

function selectNone(type){
  if(type === 'platform')  { selP.clear();  renderGroup(platforms, selP, 'platformGrid', 'platformBlock'); }
  else if(type === 'brand'){ selB.clear();  renderGroup(brands,    selB, 'brandGrid',    'brandBlock'); }
  else if(type === 'spBrand'){ selSB.clear(); renderGroup(brands, selSB, 'spBrandGrid'); }
}

function updateSelectAllBtns(){
  const pBtn  = document.getElementById('platformAllBtn');
  const bBtn  = document.getElementById('brandAllBtn');
  const sbBtn = document.getElementById('spBrandAllBtn');
  if(pBtn)  pBtn.textContent  = selP.size  === platforms.length ? '✓ 已全選' : '全選';
  if(bBtn)  bBtn.textContent  = selB.size  === brands.length    ? '✓ 已全選' : '全選';
  if(sbBtn) sbBtn.textContent = selSB.size === brands.length    ? '✓ 已全選' : '全選';
}

function updateCount(){
  const hasBrand = selB.size > 0;
  // CYBERBIZ only works when brand is selected
  const effectiveCount = selP.size === 0 ? 0
    : hasBrand ? selP.size
    : selP.size - (selP.has('cyberbiz') ? 1 : 0);

  const warn = document.getElementById('platformWarn');
  if(warn) warn.style.display = selP.size === 0 ? 'block' : 'none';

  let pLabel;
  if(selP.size === 0){
    pLabel = '<span style="color:#991b1b">請選擇平台</span>';
  } else if(!hasBrand && selP.has('cyberbiz') && effectiveCount < selP.size){
    pLabel = effectiveCount === platforms.length - 1
      ? `全部 ${effectiveCount} 個平台 <span style="color:#6b7280;font-size:11px">（CYBERBIZ 需搭配品牌）</span>`
      : `<strong>${effectiveCount}</strong> 個平台 <span style="color:#6b7280;font-size:11px">（CYBERBIZ 需搭配品牌）</span>`;
  } else if(selP.size === platforms.length){
    pLabel = `全部 ${platforms.length} 個平台`;
  } else {
    pLabel = `<strong>${selP.size}</strong> 個平台`;
  }

  const b = selB.size;
  document.getElementById('selectedCount').innerHTML =
    `查詢範圍：${pLabel}` +
    (b ? ` × <strong>${b}</strong> 個品牌` : ' × 關鍵字搜尋');
  document.getElementById('statPlatform').textContent = selP.size;
  document.getElementById('statBrand').textContent = selB.size;
}

function toggleResults(gridId, btnId){
  const grid = document.getElementById(gridId);
  const btn  = document.getElementById(btnId);
  const collapsed = grid.style.display === 'none';
  grid.style.display = collapsed ? '' : 'none';
  btn.textContent = collapsed ? '▲ 收合' : '▼ 展開';
}

const CONFIRM_THRESHOLD = 10;

function openModal(count, onConfirm){
  const body = document.getElementById('confirmModalBody');
  const okBtn = document.getElementById('confirmModalOkBtn');
  body.innerHTML = `即將同時開啟 <strong>${count} 個</strong> 查詢頁面（將在背景分頁開啟）。<br>確定要繼續嗎？`;
  okBtn.onclick = ()=>{ closeModal(); onConfirm(); };
  document.getElementById('confirmModal').classList.add('show');
}

function closeModal(){
  document.getElementById('confirmModal').classList.remove('show');
}

document.getElementById('confirmModal').addEventListener('click', e=>{
  if(e.target === document.getElementById('confirmModal')) closeModal();
});

const tooltip = document.getElementById('chipTooltip');
let longPressTimer = null;

function setupLongPress(btn, item){
  const show = (e)=>{
    const rect = btn.getBoundingClientRect();
    tooltip.textContent = `長按開啟 ${item.name} 官網 →`;
    tooltip.style.left = (rect.left + rect.width/2) + 'px';
    tooltip.style.top  = (rect.top - 40) + 'px';
    tooltip.style.transform = 'translateX(-50%)';
    tooltip.classList.add('show');
  };
  const hide = ()=>{ tooltip.classList.remove('show'); clearTimeout(longPressTimer); };

  btn.addEventListener('touchstart', e=>{
    longPressTimer = setTimeout(()=>{
      show(e);
      openUrl(item.official, true);
      hide();
    }, 500);
  }, { passive:true });
  btn.addEventListener('touchend',   hide);
  btn.addEventListener('touchmove',  hide);

  btn.addEventListener('mouseenter', show);
  btn.addEventListener('mouseleave', hide);
}

function getShopeeShopSearchUrl(brand, keyword){
  if(brand.shopeeShopId)
    return `https://shopee.tw/mall/search?keyword=${E(keyword)}&shop=${brand.shopeeShopId}`;
  return `https://shopee.tw/search?keyword=${E(brand.name + ' ' + keyword)}`;
}

function getOfficialSearchUrl(brand, keyword){
  if(!keyword) return brand.official;
  return brand.searchUrl ? brand.searchUrl(keyword) : brand.official;
}

function showMsgFor(msgId, text, ok=true){
  const el = document.getElementById(msgId);
  el.style.display = 'block';
  el.className = 'msg ' + (ok ? 'ok' : 'err');
  el.textContent = text;
}
function showMsg(text, ok=true){ showMsgFor('resultMsg', text, ok); }
function showSpMsg(text, ok=true){ showMsgFor('spResultMsg', text, ok); }

function setBtnLoading(btn, loadingText){
  if(!btn) return;
  if(btn.dataset.originalText === undefined) btn.dataset.originalText = btn.textContent;
  btn.textContent = loadingText;
  btn.disabled = true;
}
function clearBtnLoading(btn){
  if(!btn) return;
  if(btn.dataset.originalText !== undefined) btn.textContent = btn.dataset.originalText;
  btn.disabled = false;
}

/* ══════════════════════════════════════
   一般搜尋
   邏輯：
   - 沒選品牌 → 各平台純關鍵字搜尋；蝦皮大搜；CYBERBIZ 忽略
   - 有選品牌 → 各平台搜「品牌名 關鍵字」；蝦皮走品牌店鋪；CYBERBIZ 開品牌官網
   - 平台預設全選，有選才搜
══════════════════════════════════════ */
function doSearch(){
  const q              = document.getElementById('searchInput').value.trim();
  const targetBrands   = brands.filter(b => selB.has(b.id));
  const hasBrand       = targetBrands.length > 0;
  const activePlatforms = platforms.filter(p => selP.has(p.id));
  const hasCyberbiz    = activePlatforms.some(p => p.id === 'cyberbiz');
  const nonCyberbizPlats = activePlatforms.filter(p => p.id !== 'cyberbiz');

  if(selP.size === 0){
    const warn = document.getElementById('platformWarn');
    if(warn){ warn.style.display = 'block'; warn.scrollIntoView({behavior:'smooth', block:'center'}); }
    return;
  }
  if(!q && !hasBrand){
    showMsg('請輸入關鍵字，或選擇品牌', false);
    return;
  }

  const urls = [];
  const push = (platform, keyword, url) => { if(url) urls.push({ platform, keyword, url }); };

  if(!hasBrand){
    // 沒選品牌：純關鍵字搜尋，蝦皮大搜，CYBERBIZ 忽略
    nonCyberbizPlats.forEach(p => push(p.name, q, p.url(q)));
  } else {
    // 有選品牌：各平台搜「品牌名 關鍵字」，蝦皮走店鋪，CYBERBIZ 開官網
    nonCyberbizPlats.forEach(p => {
      targetBrands.forEach(b => {
        const kw = `${b.name} ${q}`.trim();
        const u  = p.id === 'shopee' ? getShopeeShopSearchUrl(b, q || b.name) : p.url(kw);
        push(p.name, kw, u);
      });
    });
    if(hasCyberbiz){
      targetBrands.forEach(b => push(b.name + ' 官網', q || b.name, getOfficialSearchUrl(b, q)));
    }
  }

  const btn = document.getElementById('doSearchBtn');
  const fire = ()=>{
    setBtnLoading(btn, '開啟中...');
    renderLinks(urls, 'linkItems', 'results', 'resultMsg', '--green', ()=>clearBtnLoading(btn));
  };
  if(urls.length > CONFIRM_THRESHOLD){ openModal(urls.length, fire); }
  else { fire(); }
}

document.getElementById('searchInput').addEventListener('keydown', e=>{
  if(e.key === 'Enter') doSearch();
});

/* ══════════════════════════════════════
   短蝦 / 蝦皮超市
══════════════════════════════════════ */
function renderSpPlatforms(){
  const grid = document.getElementById('spPlatformGrid');
  grid.innerHTML = '';
  specialPlatforms.forEach(p=>{
    const btn = document.createElement('button');
    btn.className = 'chip' + (selSP.has(p.id) ? ' active' : '');
    btn.dataset.id = p.id;
    btn.textContent = p.name;
    if(p.color) btn.style.setProperty('--chip-clr', p.color);
    btn.onclick = ()=>{
      selSP.has(p.id) ? selSP.delete(p.id) : selSP.add(p.id);
      renderSpPlatforms();
    };
    grid.appendChild(btn);
  });
}

function setSpMode(mode){
  spMode = mode;
  document.getElementById('modeKw').classList.toggle('active', mode === 'keyword');
  document.getElementById('modeBrand').classList.toggle('active', mode === 'brand');
  document.getElementById('spKwArea').style.display    = mode === 'keyword' ? '' : 'none';
  document.getElementById('spBrandArea').style.display = mode === 'brand'   ? '' : 'none';
  document.getElementById('spResults').style.display   = 'none';
  document.getElementById('spResultMsg').style.display = 'none';
}

function doSpSearch(){
  const activeSP = selSP.size > 0
    ? specialPlatforms.filter(p => selSP.has(p.id))
    : specialPlatforms;

  if(activeSP.length === 0){ showSpMsg('請至少選擇一個平台（短蝦或蝦皮超市）', false); return; }

  const urls = [];

  if(spMode === 'keyword'){
    const q = document.getElementById('spKwInput').value.trim();
    if(!q){ showSpMsg('請輸入關鍵字', false); return; }
    activeSP.forEach(p => urls.push({ platform: p.name, keyword: q, url: p.url(q) }));
  } else {
    const targetBrands = brands.filter(b => selSB.has(b.id));
    if(!targetBrands.length){ showSpMsg('請選擇至少一個品牌', false); return; }
    const spBrandKw = (document.getElementById('spBrandKwInput').value || '').trim();
    activeSP.forEach(p => {
      targetBrands.forEach(b => {
        const q = spBrandKw ? `${b.name} ${spBrandKw}` : b.name;
        urls.push({ platform: p.name, keyword: q, url: p.url(q) });
      });
    });
  }

  const btn = document.getElementById(spMode === 'keyword' ? 'spSearchBtnKw' : 'spSearchBtnBrand');
  const fire = ()=>{
    setBtnLoading(btn, '開啟中...');
    renderLinks(urls, 'spLinkItems', 'spResults', 'spResultMsg', '--orange', ()=>clearBtnLoading(btn));
  };
  if(urls.length > CONFIRM_THRESHOLD){ openModal(urls.length, fire); }
  else { fire(); }
}

document.getElementById('spKwInput').addEventListener('keydown', e=>{
  if(e.key === 'Enter') doSpSearch();
});

document.getElementById('spBrandKwInput').addEventListener('keydown', e=>{
  if(e.key === 'Enter') doSpSearch();
});

function renderLinks(urls, gridId, resultsId, msgId, colorSuffix, onDone){
  const grid = document.getElementById(gridId);
  grid.innerHTML = '';
  grid.style.display = '';

  const delay = calcDelay(urls.length);
  const total = urls.length;
  let opened = 0;

  if(total === 0){
    showMsgFor(msgId, '沒有符合條件的查詢頁面', false);
    document.getElementById(resultsId).style.display = 'none';
    if(onDone) onDone();
    return;
  }

  showMsgFor(msgId, total > 1 ? `正在開啟 0 / ${total} 個查詢頁面...` : `正在開啟查詢頁面...`);

  urls.forEach((item, i)=>{
    setTimeout(()=>{
      openUrl(item.url, false);
      opened++;
      if(opened < total){
        showMsgFor(msgId, `正在開啟 ${opened} / ${total} 個查詢頁面...`);
      } else {
        showMsgFor(msgId, `已開啟 ${total} 個查詢頁面`);
        if(onDone) onDone();
      }
    }, i * delay);

    const row = document.createElement('div');
    row.className = 'result-link';
    row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:14px;';

    const a = document.createElement('a');
    a.href = item.url;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.style.cssText = 'flex:1;display:flex;align-items:center;gap:14px;text-decoration:none;color:inherit;min-width:0;';
    const resultLeft = document.createElement('div');
    resultLeft.className = 'result-left';
    const platDiv = document.createElement('div');
    platDiv.className = `result-platform result-platform${colorSuffix}`;
    platDiv.textContent = item.platform;
    const kwDiv = document.createElement('div');
    kwDiv.className = 'result-keyword';
    kwDiv.textContent = item.keyword;
    resultLeft.appendChild(platDiv);
    resultLeft.appendChild(kwDiv);
    a.appendChild(resultLeft);

    const copyBtn = document.createElement('button');
    copyBtn.className = 'copy-btn';
    copyBtn.title = '複製連結';
    copyBtn.innerHTML = '⎘';
    copyBtn.onclick = (e)=>{
      e.preventDefault();
      e.stopPropagation();
      navigator.clipboard.writeText(item.url).then(()=>{
        copyBtn.textContent = '✓';
        copyBtn.classList.add('copied');
        setTimeout(()=>{ copyBtn.innerHTML = '⎘'; copyBtn.classList.remove('copied'); }, 1500);
      }).catch(()=>{
        copyBtn.textContent = '✗';
        setTimeout(()=>{ copyBtn.innerHTML = '⎘'; }, 1500);
      });
    };

    const arrow = document.createElement('div');
    arrow.className = 'result-arrow';
    arrow.textContent = '↗';
    a.appendChild(arrow);

    row.appendChild(a);
    row.appendChild(copyBtn);
    grid.appendChild(row);
  });

  const toggleBtn = document.getElementById(
    gridId === 'linkItems' ? 'resultsToggleBtn' : 'spResultsToggleBtn'
  );
  if(toggleBtn) toggleBtn.textContent = '▲ 收合';

  document.getElementById(resultsId).style.display = 'block';
}

document.getElementById('doSearchBtn').addEventListener('click', doSearch);
document.getElementById('platformAllBtn').addEventListener('click', ()=>selectAll('platform'));
document.getElementById('platformClearBtn').addEventListener('click', ()=>selectNone('platform'));
document.getElementById('brandAllBtn').addEventListener('click', ()=>selectAll('brand'));
document.getElementById('brandClearBtn').addEventListener('click', ()=>selectNone('brand'));
document.getElementById('resultsToggleBtn').addEventListener('click', ()=>toggleResults('linkItems','resultsToggleBtn'));
document.getElementById('modeKw').addEventListener('click', ()=>setSpMode('keyword'));
document.getElementById('modeBrand').addEventListener('click', ()=>setSpMode('brand'));
document.getElementById('spSearchBtnKw').addEventListener('click', doSpSearch);
document.getElementById('spSearchBtnBrand').addEventListener('click', doSpSearch);
document.getElementById('spBrandAllBtn').addEventListener('click', ()=>selectAll('spBrand'));
document.getElementById('spBrandClearBtn').addEventListener('click', ()=>selectNone('spBrand'));
document.getElementById('spResultsToggleBtn').addEventListener('click', ()=>toggleResults('spLinkItems','spResultsToggleBtn'));
document.getElementById('modalCancelBtn').addEventListener('click', closeModal);

document.getElementById('clearSearchBtn').addEventListener('click', ()=>{
  document.getElementById('searchInput').value = '';
  document.getElementById('searchInput').focus();
});
document.getElementById('clearSpKwBtn').addEventListener('click', ()=>{
  document.getElementById('spKwInput').value = '';
  document.getElementById('spKwInput').focus();
});
document.getElementById('clearSpBrandKwBtn').addEventListener('click', ()=>{
  document.getElementById('spBrandKwInput').value = '';
  document.getElementById('spBrandKwInput').focus();
});

/* ══════════════════════════════════════
   初始化：平台預設全選，品牌預設全不選
══════════════════════════════════════ */
platforms.forEach(p => selP.add(p.id));
renderGroup(platforms, selP, 'platformGrid', 'platformBlock');
renderGroup(brands,    selB, 'brandGrid',    'brandBlock');
renderGroup(brands,    selSB,'spBrandGrid');
renderSpPlatforms();

// 特殊平台預設全選
specialPlatforms.forEach(p => selSP.add(p.id));
renderSpPlatforms();
