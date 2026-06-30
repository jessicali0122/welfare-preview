/* ── AI 午茶助手 teaAI.js ──────────────────────────────── */
(function () {
  'use strict';

  /* ── 權限 ── */
  function canAI() {
    return typeof can === 'function' && can('hightea.manage');
  }

  /* ── 初始化：wrap htSwitchListTab + 顯示 tab ── */
  function teaAIBoot() {
    var btn = document.getElementById('ht-tab-ai');
    if (!btn) return;               // HTML 未就緒，稍後由 DOMContentLoaded 處理
    if (!canAI()) { btn.style.display = 'none'; return; }
    btn.style.display = '';

    /* wrap htSwitchListTab 以處理 'ai' panel */
    if (!window._teaAIHooked) {
      window._teaAIHooked = true;
      var orig = window.htSwitchListTab;
      window.htSwitchListTab = function (tab) {
        orig(tab);
        var aiPanel = document.getElementById('ht-panel-ai');
        if (aiPanel) aiPanel.style.display = (tab === 'ai') ? '' : 'none';
        if (tab === 'ai') teaAIRenderForm();
      };
    }
  }

  /* 在登入後也呼叫一次（某些流程 DOM 已就緒但角色剛更新） */
  window.teaAIBoot = teaAIBoot;
  document.addEventListener('DOMContentLoaded', function () {
    teaAIBoot();
    /* 若登入流程在 DOMContentLoaded 之後才完成，稍後再試一次 */
    setTimeout(teaAIBoot, 2500);
  });

  /* ── 表單渲染 ── */
  function teaAIRenderForm() {
    var panel = document.getElementById('ht-panel-ai');
    if (!panel) return;
    /* 已渲染過就不重建（保留使用者已填的值）*/
    if (panel.querySelector('.teaai-form')) return;

    panel.innerHTML =
      '<div class="teaai-wrap">'
      + '<div class="teaai-header">'
      +   '<div class="teaai-icon">✨</div>'
      +   '<div class="teaai-title">AI 午茶助手</div>'
      +   '<div class="teaai-subtitle">告訴我你的需求，AI 幫你規劃最適合的午茶方案</div>'
      + '</div>'
      + '<div class="teaai-form">'
      +   _fieldHtml('人數', '<input id="teaai-people" type="number" min="1" class="teaai-input" placeholder="例：20">')
      +   _fieldHtml('預算（元）', '<input id="teaai-budget" type="number" min="0" class="teaai-input" placeholder="例：5000">')
      +   _checksHtml()
      +   _fieldHtml('特殊需求 <span style="font-weight:400;color:#94a3b8">（選填）</span>',
            '<textarea id="teaai-special" class="teaai-textarea" rows="3" placeholder="例：不要炸物、素食優先、不要最近吃過的…"></textarea>')
      +   '<button id="teaai-run-btn" class="teaai-run-btn" onclick="teaAIPlan()">✨ AI 幫我規劃</button>'
      + '</div>'
      + '<div id="teaai-result-area"></div>'
      + '</div>';

    /* checkbox 點擊切換 checked class */
    panel.querySelectorAll('.teaai-check-label').forEach(function (lbl) {
      lbl.addEventListener('click', function () {
        var cb = lbl.querySelector('input[type="checkbox"]');
        cb.checked = !cb.checked;
        lbl.classList.toggle('checked', cb.checked);
      });
    });
  }

  function _fieldHtml(label, inputHtml) {
    return '<div class="teaai-field">'
      + '<label class="teaai-label">' + label + '</label>'
      + inputHtml
      + '</div>';
  }

  function _checksHtml() {
    var items = [
      { v: '飲料', icon: '🧋' },
      { v: '甜點', icon: '🍰' },
      { v: '鹹食', icon: '🥪' },
      { v: '水果', icon: '🍓' }
    ];
    return '<div class="teaai-field">'
      + '<label class="teaai-label">餐點類型</label>'
      + '<div class="teaai-checks">'
      + items.map(function (it) {
          return '<label class="teaai-check-label">'
            + '<input type="checkbox" value="' + it.v + '">'
            + it.icon + ' ' + it.v
            + '</label>';
        }).join('')
      + '</div></div>';
  }

  /* ── 執行規劃 ── */
  window.teaAIPlan = function () {
    if (!canAI()) return;
    var peopleEl  = document.getElementById('teaai-people');
    var budgetEl  = document.getElementById('teaai-budget');
    var specialEl = document.getElementById('teaai-special');
    var resultArea = document.getElementById('teaai-result-area');
    var runBtn    = document.getElementById('teaai-run-btn');

    var people  = parseInt((peopleEl  && peopleEl.value)  || '0', 10);
    var budget  = parseInt((budgetEl  && budgetEl.value)  || '0', 10);
    var types   = [];
    document.querySelectorAll('#ht-panel-ai .teaai-check-label.checked').forEach(function (lbl) {
      types.push(lbl.querySelector('input').value);
    });
    var special = (specialEl && specialEl.value.trim()) || '';

    if (!people || people < 1) { _teaToast('請輸入人數'); return; }
    if (!budget || budget < 1) { _teaToast('請輸入預算'); return; }

    /* 顯示 spinner */
    if (runBtn) { runBtn.disabled = true; runBtn.textContent = '⏳ AI 思考中…'; }
    if (resultArea) {
      resultArea.innerHTML =
        '<div class="teaai-spinner-wrap">'
        + '<div class="teaai-spinner"></div>'
        + '<div class="teaai-spinner-text">AI 正在為你規劃午茶方案…</div>'
        + '</div>';
    }

    function _done() {
      if (runBtn) { runBtn.disabled = false; runBtn.textContent = '✨ AI 幫我規劃'; }
    }

    /* ── 嘗試透過 GAS 取得結果，失敗時 fallback 到本地 mock ── */
    var svc = window.TeaAIService;
    if (svc && typeof svc.recommendTea === 'function') {
      svc.recommendTea({ people: people, budget: budget, category: types, requirement: special })
        .then(function (r) {
          _done();
          if (r && r.success && Array.isArray(r.plans) && r.plans.length) {
            var plans = r.plans.map(function (p) {
              return {
                name:  p.title      || '推薦方案',
                desc:  p.restaurant || '',
                items: Array.isArray(p.items) ? p.items : [],
                cost:  p.price      || 0,
                reason: p.reason    || ''
              };
            });
            _renderResult(plans, '', 'gemini');
          } else {
            var errMsg = (r && r.error) ? r.error : '';
            if (errMsg) _teaToast('AI 規劃失敗：' + errMsg);
            _localMockResult(people, budget, types, special);
          }
        })
        .catch(function () {
          _done();
          _localMockResult(people, budget, types, special);
        });
    } else {
      /* TeaAIService 尚未載入時直接用本地 mock */
      setTimeout(function () {
        _done();
        _localMockResult(people, budget, types, special);
      }, 1800);
    }
  };

  /* ── 本地 Mock（GAS 未回應時的 fallback）── */
  function _localMockResult(people, budget, types, special) {
    var perPerson = Math.round(budget / people);
    var want = types.length ? types : ['飲料', '甜點'];
    var plans = _buildPlans(people, budget, perPerson, want, special);
    var tip   = _buildTip(people, budget, special);
    _renderResult(plans, tip, 'mock');
  }

  /* ── 共用渲染（GAS 結果 & 本地 mock 皆走這裡）── */
  function _renderResult(plans, tip, source) {
    var resultArea = document.getElementById('teaai-result-area');
    if (!resultArea) return;

    var sourceLabel = source === 'gemini'
      ? '<span class="teaai-result-tag" style="background:#ede9fe;color:#7c3aed">✨ Gemini</span>'
      : source === 'mock'
        ? '<span class="teaai-result-tag" style="background:#f1f5f9;color:#64748b">本地預覽</span>'
        : '';

    var html = '<div class="teaai-result-wrap">'
      + '<div class="teaai-result-header">'
      +   '🎯 AI 推薦方案 '
      +   '<span class="teaai-result-tag">共 ' + plans.length + ' 個方案</span>'
      +   sourceLabel
      + '</div>';

    plans.forEach(function (plan, i) {
      var rankClass = ['r1', 'r2', 'r3'][i] || 'r3';
      var rankLabel = ['🥇', '🥈', '🥉'][i] || (i + 1);
      html += '<div class="teaai-plan-card">'
        + '<div class="teaai-plan-card-header">'
        +   '<div class="teaai-plan-rank ' + rankClass + '">' + rankLabel + '</div>'
        +   '<div><div class="teaai-plan-name">' + htEsc(plan.name) + '</div>'
        +   '<div class="teaai-plan-desc">' + htEsc(plan.desc) + '</div></div>'
        + '</div>'
        + '<div class="teaai-plan-body">'
        +   '<div class="teaai-plan-row">'
        +     '<span class="teaai-plan-row-label">品項</span>'
        +     '<div class="teaai-plan-items">'
        +     (plan.items || []).map(function (it) {
                return '<span class="teaai-plan-item-chip">' + htEsc(it) + '</span>';
              }).join('')
        +     '</div>'
        +   '</div>'
        +   '<div class="teaai-plan-row">'
        +     '<span class="teaai-plan-row-label">預估花費</span>'
        +     '<span class="teaai-plan-budget-chip">NT$' + Number(plan.cost || 0).toLocaleString() + '</span>'
        +   '</div>'
        + (plan.reason ? '<div class="teaai-plan-row" style="align-items:flex-start">'
        +   '<span class="teaai-plan-row-label">理由</span>'
        +   '<span style="font-size:12px;color:#64748b;line-height:1.6">' + htEsc(plan.reason) + '</span>'
        + '</div>' : '')
        + '</div>'
        + '</div>';
    });

    if (tip) {
      html += '<div class="teaai-plan-tip">'
        + '<span class="teaai-plan-tip-icon">💡</span>'
        + htEsc(tip)
        + '</div>';
    }

    html += '<button class="teaai-redo-btn" onclick="teaAIPlan()">🔄 重新規劃</button>';
    html += '</div>';

    resultArea.innerHTML = html;
    resultArea.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  /* ── 方案生成邏輯 ── */
  function _buildPlans(people, budget, perPerson, types, special) {
    var isVeg = /素食|蔬食|全素|齋/i.test(special);
    var noFried = /炸物|油炸/i.test(special);

    var allTemplates = [
      {
        need: ['飲料'],
        name: '手搖飲料套組',
        desc: '人人一杯，品項多元，適合輕鬆下午茶',
        items: ['珍珠奶茶', '茉莉綠茶', '烏龍拿鐵', '芋頭鮮奶'],
        unitCost: 60
      },
      {
        need: ['甜點'],
        name: '甜點拼盤',
        desc: '精選烘焙甜點，擺盤美觀、適合拍照打卡',
        items: ['法式可頌', '起司蛋糕', '馬卡龍', '瑪德蓮'],
        unitCost: 90
      },
      {
        need: ['鹹食'],
        name: '輕食鹹點組合',
        desc: '鹹香不膩，飽足感佳，適合下午補充能量',
        items: noFried ? ['三明治', '飯糰', '生菜沙拉', '起司吐司'] : ['雞肉捲', '薯餅', '鮮蔬三明治', '帕尼尼'],
        unitCost: 100
      },
      {
        need: ['水果'],
        name: '季節水果盤',
        desc: '新鮮時令水果，清爽解膩，健康首選',
        items: ['西瓜', '葡萄', '奇異果', '草莓'],
        unitCost: 70
      },
      {
        need: ['飲料', '甜點'],
        name: '飲料 × 甜點雙拼',
        desc: '飲料搭配甜點，最受歡迎的午茶組合',
        items: ['手搖飲（人人一杯）', '蛋糕捲', '布丁', '可頌'],
        unitCost: 130
      },
      {
        need: ['飲料', '鹹食'],
        name: '飲料 × 輕食套組',
        desc: '一飲一食，均衡搭配，省錢又飽足',
        items: ['飲料（人人一杯）', noFried ? '鮮蔬三明治' : '雞腿飯糰', '起司吐司'],
        unitCost: 140
      },
      {
        need: ['甜點', '水果'],
        name: '甜蜜水果甜點盤',
        desc: '甜點加水果，清甜搭配，下午茶最佳選擇',
        items: ['季節水果盤', '馬卡龍', '芒果奶酪', '鮮果塔'],
        unitCost: 120
      },
      {
        need: ['飲料', '甜點', '鹹食'],
        name: '三合一午茶豪華套餐',
        desc: '飲料、甜點、鹹食一次滿足，適合正式聚會',
        items: ['手搖飲（人人一杯）', '甜點拼盤', noFried ? '輕食三明治' : '雞肉捲', '水果切盤'],
        unitCost: 200
      }
    ];

    /* 篩選符合需求的方案 */
    var matched = allTemplates.filter(function (t) {
      if (types.length === 0) return true;
      return t.need.some(function (n) { return types.indexOf(n) !== -1; });
    });

    /* 排序：最接近預算且不超過 */
    matched.sort(function (a, b) {
      var da = Math.abs(a.unitCost * people - budget);
      var db = Math.abs(b.unitCost * people - budget);
      return da - db;
    });

    /* 取前 3 個，並計算實際花費 */
    return matched.slice(0, 3).map(function (t) {
      var cost = Math.min(t.unitCost * people, budget);
      /* 若該方案預算不夠，降低品項數 */
      var itemCount = perPerson < 50 ? 2 : perPerson < 100 ? 3 : 4;
      return {
        name: t.name,
        desc: t.desc,
        items: t.items.slice(0, itemCount),
        cost: cost
      };
    });
  }

  function _buildTip(people, budget, special) {
    var perPerson = Math.round(budget / people);
    var tips = [];
    if (perPerson < 80)  tips.push('每人預算偏低，建議選擇手搖飲料或水果為主，控制品項數量。');
    if (perPerson >= 80 && perPerson < 150) tips.push('每人預算適中，飲料 + 一款點心是最划算的組合。');
    if (perPerson >= 150) tips.push('每人預算充足，可以嘗試主題甜點桌或多樣組合，讓午茶更豐盛！');
    if (/素食|蔬食/i.test(special)) tips.push('已標記素食需求，建議提前與店家確認。');
    if (people >= 30) tips.push('人數較多，建議提前 3 天預訂，避免備料不足。');
    tips.push('以上為 AI 模擬推薦，實際訂購請依店家菜單和現況調整。');
    return tips.join(' ');
  }

  /* ── 小 toast ── */
  function _teaToast(msg) {
    if (typeof toast === 'function') { toast(msg, 'warning'); return; }
    alert(msg);
  }

  /* ── htEsc fallback（防止 XSS） ── */
  function htEsc(s) {
    if (typeof window.htEsc === 'function') return window.htEsc(s);
    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

})();
