/**
 * @param {{tabs: {id: string, label: string, icon: any}[], activeTab: string, onChange: (id: string) => void}} props
 */
export default function TabBar({ tabs, activeTab, onChange }) {
  return (
    <div className="border-b border-line px-6">
      <div className="flex gap-1">
        {tabs.map(({ id, label, icon: Icon }) => {
          const active = activeTab === id;
          return (
            <button
              key={id}
              onClick={() => onChange(id)}
              className={`flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 -mb-px transition-colors ${
                active
                  ? 'border-accent text-accent'
                  : 'border-transparent text-muted hover:text-ink'
              }`}
            >
              <Icon size={16} strokeWidth={2} />
              {label}
            </button>
          );
        })}
      </div>
    </div>
  );
}
